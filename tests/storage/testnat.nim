import std/[net]
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/libp2p/protocols/connectivity/autonat/types
import pkg/libp2p/protocols/connectivity/autonatv2/service except setup
import pkg/libp2p/protocols/connectivity/autonatv2/client except setup
import pkg/libp2p/protocols/connectivity/autonatv2/types as autonatv2Types
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
import pkg/libp2p/protocols/connectivity/dcutr/core as dcutrCore
import pkg/libp2p/multistream
import pkg/libp2p/services/autorelayservice except setup
import pkg/results

import ./helpers
import ../asynctest
import ../../storage/utils/natutils
import ../../storage/nat
import ../../storage/discovery
import ../../storage/rng
import ../../storage/utils

type MockNatPortMapper = ref object of NatPortMapper
  mappedPorts: Option[(Port, Port, MappingProtocol)]

method mapNatPorts*(
    m: MockNatPortMapper
): Future[Option[(Port, Port, MappingProtocol)]] {.
    async: (raises: [CancelledError]), gcsafe
.} =
  m.mappedPorts

type MockAutonatV2Client = ref object of AutonatV2Client
  reqAddrs: seq[MultiAddress]

method sendDialRequest*(
    self: MockAutonatV2Client, pid: PeerId, testAddrs: seq[MultiAddress]
): Future[AutonatV2Response] {.
    async: (raises: [AutonatV2Error, CancelledError, DialFailedError, LPStreamError])
.} =
  self.reqAddrs = testAddrs
  AutonatV2Response(reachability: Unknown)

asyncchecksuite "NAT - handleNatStatus":
  var sw: Switch
  var key: PrivateKey
  var disc: Discovery
  var autoRelay: AutoRelayService

  setup:
    autoRelay =
      AutoRelayService.new(1, relayClientModule.RelayClient.new(), nil, Rng.instance())
    key = PrivateKey.random(Rng.instance()).get()
    disc = Discovery.new(key, announceAddrs = @[])
    sw = newStandardSwitch()
    await sw.start()

  teardown:
    await sw.stop()

    if autoRelay.isRunning:
      await autoRelay.stop(sw)

  let discoveryPort = Port(8090)

  test "handleNatStatus announces mapped address when NotReachable and UPnP succeeds":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(
      mappedPorts: some((Port(9000), Port(9001), MappingProtocol.UPnP))
    )

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check disc.announceAddrs ==
      @[MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")]
    check not autoRelay.isRunning
    check disc.protocol.clientMode

  test "handleNatStatus starts autoRelay when NotReachable and no dialBackAddr":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.protocol.clientMode

  test "handleNatStatus starts autoRelay when NotReachable and dialBackAddr but no mapped ports":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus stops relay and exits client mode when Reachable":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    disc.protocol.clientMode = true
    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      Reachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check not autoRelay.isRunning
    check not disc.protocol.clientMode

  test "announcePeerInfoAddrs excludes relay circuit addresses":
    let circuitAddr = MultiAddress
      .init("/ip4/1.2.3.4/tcp/4040/p2p/" & $sw.peerInfo.peerId & "/p2p-circuit")
      .expect("valid")
    sw.peerInfo.addrs.add(circuitAddr)

    announcePeerInfoAddrs(disc, sw.peerInfo, discoveryPort)

    check circuitAddr notin disc.announceAddrs
    check disc.announceAddrs == sw.peerInfo.addrs.filterIt(it != circuitAddr)

  test "announcePeerInfoAddrs does nothing when addresses are already announced":
    announcePeerInfoAddrs(disc, sw.peerInfo, discoveryPort)
    let seqNo = disc.getSpr().data.seqNo

    announcePeerInfoAddrs(disc, sw.peerInfo, discoveryPort)

    check disc.getSpr().data.seqNo == seqNo

  test "peerInfo observer announces addresses when Reachable":
    let autonat = AutonatV2Service.new(Rng.instance())
    discard setupPeerInfoObserver(
      sw, autonat, disc, NatPortMapper(discoveryPort: discoveryPort)
    )
    autonat.networkReachability = Reachable

    sw.peerInfo.listenAddrs.add(
      MultiAddress.init("/ip4/1.2.3.4/tcp/9999").expect("valid")
    )
    await sw.peerInfo.update()

    check disc.announceAddrs == sw.peerInfo.addrs

  test "peerInfo observer announces the mapped external UDP port when a mapping is active":
    let autonat = AutonatV2Service.new(Rng.instance())
    let mapper =
      NatPortMapper(discoveryPort: discoveryPort, activeUdpPort: some(Port(40001)))
    discard setupPeerInfoObserver(sw, autonat, disc, mapper)
    autonat.networkReachability = Reachable

    sw.peerInfo.listenAddrs.add(
      MultiAddress.init("/ip4/1.2.3.4/tcp/9999").expect("valid")
    )
    await sw.peerInfo.update()

    let sprAddrs = disc.getSpr().data.addresses.mapIt(it.address)
    check MultiAddress.init("/ip4/1.2.3.4/udp/40001").expect("valid") in sprAddrs
    check MultiAddress.init("/ip4/1.2.3.4/udp/" & $discoveryPort).expect("valid") notin
      sprAddrs

  test "peerInfo observer does not announce when the node is not Reachable":
    let autonat = AutonatV2Service.new(Rng.instance())
    discard setupPeerInfoObserver(
      sw, autonat, disc, NatPortMapper(discoveryPort: discoveryPort)
    )
    autonat.networkReachability = NotReachable

    sw.peerInfo.listenAddrs.add(
      MultiAddress.init("/ip4/1.2.3.4/tcp/9999").expect("valid")
    )
    await sw.peerInfo.update()

    check disc.announceAddrs == newSeq[MultiAddress]()

  test "autonat dial request includes the observed addresses as candidates":
    # Reproduces vacp2p/nim-libp2p#2600: until that fix is vendored, the
    # dial request only contains peerInfo.addrs (private listen addrs), so
    # a NATed node never submits a dialable candidate.
    let client = MockAutonatV2Client()
    let autonat = AutonatV2Service.new(Rng.instance(), client)
    service.setup(autonat, sw)
    await autonat.start(sw)

    let observed = MultiAddress.init("/ip4/8.8.8.8/tcp/4001").expect("valid")
    for _ in 0 ..< 3: # minCount: 3 observations before the manager trusts an addr
      discard sw.peerStore.identify.observedAddrManager.addObservation(observed)

    let sw2 = newStandardSwitch()
    await sw2.start()
    await sw.connect(sw2.peerInfo.peerId, sw2.peerInfo.addrs)

    check eventually(observed in client.reqAddrs)

    await autonat.stop(sw)
    await sw2.stop()

asyncchecksuite "NAT - Hole punching":
  test "setupHolePunching mounts the dcutr protocol on the switch":
    let sw = newStandardSwitch()
    discard setupHolePunching(sw)
    check sw.ms.handlers.anyIt(dcutrCore.DcutrCodec in it.protos)

  test "holePunchIfRelayed returns early when the peer has no connections":
    let sw1 = newStandardSwitch()
    let sw2 = newStandardSwitch()
    await allFutures(sw1.start(), sw2.start())

    await holePunchIfRelayed(sw1, sw2.peerInfo.peerId)

    await allFutures(sw1.stop(), sw2.stop())

  test "holePunchIfRelayed returns early when a direct connection already exists":
    let sw1 = newStandardSwitch()
    let sw2 = newStandardSwitch()
    await allFutures(sw1.start(), sw2.start())

    await sw1.connect(sw2.peerInfo.peerId, sw2.peerInfo.addrs)
    check sw1.isConnected(sw2.peerInfo.peerId)

    await holePunchIfRelayed(sw1, sw2.peerInfo.peerId)

    check sw1.isConnected(sw2.peerInfo.peerId)
    await allFutures(sw1.stop(), sw2.stop())
