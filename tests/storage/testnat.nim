import std/[net]
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/libp2p/protocols/connectivity/autonat/types
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
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
    key = PrivateKey.random(Rng.instance[]).get()
    disc = Discovery.new(key, announceAddrs = @[])
    sw = newStandardSwitch()
    await sw.start()

  teardown:
    await sw.stop()

    if autoRelay.isRunning:
      discard await autoRelay.stop(sw)

  let discoveryPort = Port(8090)

  test "handleNatStatus announces mapped address when NotReachable and UPnP succeeds":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper =
      MockNatPortMapper(mappedPorts: some((Port(9000), Port(9001), MappingProtocol.UPnP)))

    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check disc.announceAddrs ==
      @[MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")]
    check not autoRelay.isRunning
    check disc.protocol.clientMode

  test "handleNatStatus starts autoRelay when NotReachable and UPnP failed":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.protocol.clientMode

  test "handleNatStatus starts autoRelay when NotReachable and mapping fails":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus does not announce address when Reachable and no dialBackAddr":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    await mapper.handleNatStatus(
      Reachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check disc.announceAddrs == newSeq[MultiAddress]()
    check not autoRelay.isRunning
    check not disc.protocol.clientMode

  test "handleNatStatus stops relay and announces dialBackAddr when Reachable":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    discard await autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      Reachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check not autoRelay.isRunning
    check disc.announceAddrs == @[dialBack]
    check not disc.protocol.clientMode
