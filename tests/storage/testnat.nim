import std/[net]
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/libp2p/protocols/connectivity/autonat/types
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

    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.protocol.clientMode

  test "handleNatStatus starts autoRelay when NotReachable and dialBackAddr but no mapped ports":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus does nothing when Reachable and no dialBackAddr":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    autorelayservice.setup(autoRelay, sw)
    disc.protocol.clientMode = true
    await mapper.handleNatStatus(
      Reachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus stops relay and announces dialBackAddr when Reachable":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    disc.protocol.clientMode = true
    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      Reachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check not autoRelay.isRunning
    check disc.announceAddrs == @[dialBack]
    check not disc.protocol.clientMode

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
