import std/[net]
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/libp2p/protocols/connectivity/autonat/types
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
import pkg/libp2p/services/autorelayservice except setup
import pkg/libp2p/observedaddrmanager
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
  activeMapping: bool

method mapNatPorts*(
    m: MockNatPortMapper
): Future[Option[(Port, Port, MappingProtocol)]] {.
    async: (raises: [CancelledError]), gcsafe
.} =
  m.mappedPorts

method hasMappingIds*(m: MockNatPortMapper): bool =
  m.activeMapping

asyncchecksuite "NAT reaction - port mapping":
  var sw: Switch
  var key: PrivateKey
  var disc: Discovery
  var autoRelay: AutoRelayService

  setup:
    autoRelay = AutoRelayService.new(
      1, relayClientModule.RelayClient.new(), nil, Rng.instance().libp2pRng
    )
    key = PrivateKey.random(Rng.instance().libp2pRng).get()
    disc = Discovery.new(key, announceAddrs = @[])
    sw = newStandardSwitch()
    await sw.start()

  teardown:
    await sw.stop()

    if autoRelay.isRunning:
      await autoRelay.stop(sw)

  let discoveryPort = Port(8090)

  test "handleNatStatus keeps relay off when NotReachable and mapping succeeds":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(
      mappedPorts: some((Port(9000), Port(9001), MappingProtocol.UPnP))
    )

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    # A mapping doesn't guarantee reachability, so the relay stays off until
    # AutoNAT confirms Reachable.
    check not autoRelay.isRunning
    check disc.protocol.clientMode

  test "handleNatStatus starts autoRelay when NotReachable and no dialBackAddr but no mapped ports":
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

  test "handleNatStatus tears down an active mapping and starts relay when NotReachable with dialBackAddr":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(activeMapping: true)

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus tears down an active mapping and starts relay when NotReachable without dialBackAddr":
    let mapper = MockNatPortMapper(activeMapping: true)

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus stops relay and exits client mode when mapping is created and node is Reachable":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    disc.protocol.clientMode = true
    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      Reachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check not autoRelay.isRunning
    check not disc.protocol.clientMode

  test "handleNatStatus does nothing after the mapper is stopped":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(
      mappedPorts: some((Port(9000), Port(9001), MappingProtocol.UPnP))
    )
    mapper.stop()

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check not autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()

asyncchecksuite "NAT reaction - address announcing":
  var sw: Switch
  var key: PrivateKey
  var disc: Discovery
  var autoRelay: AutoRelayService

  setup:
    autoRelay = AutoRelayService.new(
      1, relayClientModule.RelayClient.new(), nil, Rng.instance().libp2pRng
    )
    key = PrivateKey.random(Rng.instance().libp2pRng).get()
    disc = Discovery.new(key, announceAddrs = @[])
    sw = newStandardSwitch()
    await sw.start()

  teardown:
    await sw.stop()
    if autoRelay.isRunning:
      await autoRelay.stop(sw)

  let discoveryPort = Port(8090)

  test "handleNatStatus announces the dial-back address when Reachable":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")

    let mapper = NatPortMapper(discoveryPort: discoveryPort)
    await mapper.handleNatStatus(
      Reachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check disc.announceAddrs == @[dialBack]

  test "handleNatStatus announces the mapped external UDP port when a mapping is active":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")

    let mapper =
      NatPortMapper(discoveryPort: discoveryPort, activeUdpPort: some(Port(40001)))
    await mapper.handleNatStatus(
      Reachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    let sprAddrs = disc.getSpr().data.addresses.mapIt(it.address)
    check MultiAddress.init("/ip4/1.2.3.4/udp/40001").expect("valid") in sprAddrs
    check MultiAddress.init("/ip4/1.2.3.4/udp/" & $discoveryPort).expect("valid") notin
      sprAddrs

  test "handleNatStatus does not announce when Reachable without a dial-back address":
    let mapper = NatPortMapper(discoveryPort: discoveryPort)
    await mapper.handleNatStatus(
      Reachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check disc.announceAddrs == newSeq[MultiAddress]()

  test "mapped-addr mapper injects the mapped port as the first candidate":
    const mockMappedTcpPort = 40000

    setupMappedAddrMapper(
      sw, NatPortMapper(activeTcpPort: some(Port(mockMappedTcpPort)))
    )

    # Reach the observation quorum so guessDialableAddr trusts 8.8.8.8
    let observed = MultiAddress.init("/ip4/8.8.8.8/tcp/4001").expect("valid")
    let quorum = 3
    for _ in 0 ..< quorum:
      discard sw.peerStore.identify.observedAddrManager.addObservation(observed)

    await sw.peerInfo.update()

    # Ensure that the address mapper injects the mapped port as the first candidate
    # after peer info update
    check sw.peerInfo.addrs[0] ==
      MultiAddress.init("/ip4/8.8.8.8/tcp/" & $mockMappedTcpPort).expect("valid")

  test "mapped-addr mapper is a no-op without an active mapping":
    setupMappedAddrMapper(sw, NatPortMapper())

    let observed = MultiAddress.init("/ip4/8.8.8.8/tcp/4001").expect("valid")
    let quorum = 3
    for _ in 0 ..< quorum:
      discard sw.peerStore.identify.observedAddrManager.addObservation(observed)

    await sw.peerInfo.update()

    # Ensure that nothing is injected because there is no active mapping
    check sw.peerInfo.addrs == sw.peerInfo.listenAddrs
