import std/sequtils
import pkg/libp2p/multiaddress
import pkg/libp2p/protocols/kademlia except PeerRecord
import pkg/libp2p_mix

import ../asynctest
import ./helpers
import ./examples
import ../../storage/discovery
import ../../storage/rng
import ../../storage/utils/mixidentity

suite "Discovery - Mix local address":
  var switch: Switch
  var disc: Discovery
  var mixProto: MixProtocol

  let
    directAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    otherAddr = MultiAddress.init("/ip4/9.9.9.9/tcp/4003").expect("valid")
    udpAddr = MultiAddress.init("/ip4/1.2.3.4/udp/4001").expect("valid")
    circuitAddr = MultiAddress
      .init(
        "/ip4/5.6.7.8/tcp/4002/p2p/16Uiu2HAmQu456Ae52JqPuqog6wCex47LLvNY8oHMBC4GRRtaStHs/p2p-circuit"
      )
      .expect("valid")

  setup:
    switch = newStandardSwitch()
    disc = Discovery.new(switch)

    # Mirror the node startup: no dialable address known yet.
    var nodeInfo = MixNodeInfo.generateRandom(0, Rng.instance().libp2pRng)
    nodeInfo.multiAddr = mixUnsetMultiAddr()
    mixProto = MixProtocol.new(nodeInfo, newStandardSwitch())
    disc.mixProto = mixProto

  test "a dialable address sets the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $directAddr

  test "a relay circuit address sets the Mix local address":
    switch.peerInfo.addrs = @[circuitAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $circuitAddr

  test "a new address replaces the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    switch.peerInfo.addrs = @[otherAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $otherAddr

  test "clearing the addresses resets the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    switch.peerInfo.addrs = @[]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $mixUnsetMultiAddr()

  test "no Mix-compatible address resets the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    switch.peerInfo.addrs = @[udpAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $mixUnsetMultiAddr()

suite "Discovery - bootstrap addresses":
  let
    publicAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    privateAddr = MultiAddress.init("/ip4/10.1.0.85/tcp/4001").expect("valid")

  proc bootstrapAddrs(disc: Discovery): seq[string] =
    disc.routingTable().peers[0].record.addresses.mapIt($it.address)

  test "a private address of a bootstrap node is kept by default":
    let disc = Discovery.new(
      newStandardSwitch(),
      bootstrapNodes = [(PeerId.example, @[publicAddr, privateAddr])],
    )

    check $privateAddr in disc.bootstrapAddrs

  test "a private address of a bootstrap node is dropped by a public address policy":
    let disc = Discovery.new(
      newStandardSwitch(),
      bootstrapNodes = [(PeerId.example, @[publicAddr, privateAddr])],
      addressPolicy = dialableMixAddressPolicy,
    )

    check $privateAddr notin disc.bootstrapAddrs

proc holdConnection(
    server: StreamServer, transp: StreamTransport
) {.async: (raises: []).} =
  ## Accept the connection and never say a word.
  try:
    await sleepAsync(1.hours)
  except CancelledError:
    discard
  await transp.closeWait()

asyncchecksuite "Discovery - findDirect":
  const
    DeadPeers = 6
    ShortLookupTimeout = 3.seconds

  var
    provider, seeker: Switch
    providerDisc, seekerDisc: Discovery
    silent: seq[StreamServer]
    cid: Cid

  setup:
    cid = Cid.example
    provider = newStandardSwitch()
    seeker = newStandardSwitch()
    providerDisc = Discovery.new(provider)
    seekerDisc = Discovery.new(seeker, lookupTimeout = ShortLookupTimeout)
    provider.mount(providerDisc.kad)
    seeker.mount(seekerDisc.kad)
    await provider.start()
    await seeker.start()

    # Peers that accept connections but never answer: every request to them
    # stalls until it times out, so a complete lookup takes much longer than
    # `ShortLookupTimeout`.
    silent = @[]
    for _ in 0 ..< DeadPeers:
      let server = createStreamServer(
        initTAddress("127.0.0.1:0"), holdConnection, flags = {ReuseAddr}
      )
      server.start()
      silent.add(server)
      let
        peerId = PeerId.example
        addrs = @[MultiAddress.init(server.localAddress()).expect("valid")]
      seeker.peerStore[AddressBook].extend(peerId, addrs)
      check seekerDisc.kad.rtable.insert(peerId)

    seeker.peerStore[AddressBook].extend(
      provider.peerInfo.peerId, provider.peerInfo.addrs
    )
    check seekerDisc.kad.rtable.insert(provider.peerInfo.peerId)

    await providerDisc.provide(cid)

  teardown:
    for server in silent:
      server.stop()
      await server.closeWait()
    await seeker.stop()
    await provider.stop()

  test "returns a provider without waiting for the rest of the lookup":
    # The silent peers keep the lookup running past the timeout; the provider
    # found in the meantime must be returned, and right away.
    let start = Moment.now()
    let found = await seekerDisc.findDirect(cid)
    let elapsed = Moment.now() - start

    check found.isSuccess
    check found.get(@[]).anyIt(it.peerId == provider.peerInfo.peerId)
    check elapsed < ShortLookupTimeout div 2
