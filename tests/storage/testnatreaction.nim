import std/[importutils, net]
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

method destroyMappingFor(m: MockNatPortMapper, id: cint) {.gcsafe.} =
  discard

type MockMapNatPortMapper = ref object of NatPortMapper
  tcpResult: Result[MappingResult, string]
  udpResult: Result[MappingResult, string]
  live: bool
  createAttempts: seq[PlumProtocol]
  destroyed: seq[cint]
  initAttempts: int

method initPlum(m: MockMapNatPortMapper): Result[void, string] {.gcsafe.} =
  inc m.initAttempts
  ok()

method hasLivePortMapping(m: MockMapNatPortMapper): bool {.gcsafe.} =
  m.portMapping.isSome and m.live

method createMappingFor(
    m: MockMapNatPortMapper, protocol: PlumProtocol, port: uint16
): Future[Result[MappingResult, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  m.createAttempts.add(protocol)
  if protocol == TCP: m.tcpResult else: m.udpResult

method destroyMappingFor(m: MockMapNatPortMapper, id: cint) {.gcsafe.} =
  m.destroyed.add(id)

proc mappingOk(id: cint, port: uint16): Result[MappingResult, string] =
  Result[MappingResult, string].ok(
    MappingResult(
      id: id,
      mapping: PlumMapping(mappingProtocol: MappingProtocol.UPnP, externalPort: port),
    )
  )

const relayId = "16Uiu2HAmQu456Ae52JqPuqog6wCex47LLvNY8oHMBC4GRRtaStHs"

proc circuitAddr(relayIp: string): MultiAddress =
  MultiAddress
    .init("/ip4/" & relayIp & "/tcp/8070/p2p/" & relayId & "/p2p-circuit")
    .expect("valid")

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
    disc = Discovery.new(key, providerAddrs = @[])
    sw = newStandardSwitch()
    await sw.start()

  teardown:
    await sw.stop()

    if autoRelay.isRunning:
      await autoRelay.stop(sw)

  let discoveryPort = Port(8090)

  test "handleNatStatus keeps relay off when NotReachable and mapping succeeds":
    skip()
    return

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

  test "handleNatStatus starts autoRelay when NotReachable with no mapped ports":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.providerAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode

  test "handleNatStatus keeps a live mapping and starts relay when NotReachable":
    privateAccess(PortMapping)
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockMapNatPortMapper(live: true)
    mapper.portMapping = some(
      PortMapping(
        tcpMappingId: cint(1),
        udpMappingId: cint(2),
        activeMappingProtocol: MappingProtocol.UPnP,
        activeTcpPort: Port(9000),
        activeUdpPort: Port(9001),
      )
    )

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.providerAddrs == newSeq[MultiAddress]()
    check disc.protocol.clientMode
    check mapper.portMapping.isSome # the live mapping is kept
    check mapper.destroyed.len == 0 # never torn down

  test "handleNatStatus recreates a dead mapping instead of pinning it":
    skip()
    return

    privateAccess(PortMapping)
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockMapNatPortMapper(
      live: false,
      tcpResult: mappingOk(cint(10), 9000),
      udpResult: mappingOk(cint(20), 9001),
    )
    mapper.portMapping = some(
      PortMapping(
        tcpMappingId: cint(1),
        udpMappingId: cint(2),
        activeMappingProtocol: MappingProtocol.UPnP,
        activeTcpPort: Port(9000),
        activeUdpPort: Port(9001),
      )
    )

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check mapper.destroyed == @[cint(1), cint(2)] # the dead mapping is torn down
    check mapper.portMapping.isSome # replaced by a fresh one
    check not autoRelay.isRunning # direct path kept, no relay

  test "handleNatStatus stops relay and exits client mode when mapping is created and node is Reachable":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    disc.protocol.clientMode = true
    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      Reachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
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
    check disc.providerAddrs == newSeq[MultiAddress]()

  test "handleNatStatus retries the port mapping on the next NotReachable after a failure":
    skip()
    return

    # A failed mapping must not disable the mapper: close() resets plum so the
    # next AutoNAT iteration re-runs discover and tries again.
    let mapper = MockMapNatPortMapper(
      tcpResult: Result[MappingResult, string].err("tcp mapping failed")
    )

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )
    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check mapper.initAttempts == 2
    check mapper.createAttempts == @[PlumProtocol.TCP, PlumProtocol.TCP]

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
    disc = Discovery.new(key, providerAddrs = @[])
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

    check disc.providerAddrs == @[dialBack]

  test "handleNatStatus does not announce when Reachable without a dial-back address":
    let mapper = NatPortMapper(discoveryPort: discoveryPort)
    await mapper.handleNatStatus(
      Reachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check disc.providerAddrs == newSeq[MultiAddress]()

  test "handleNatStatus clears the DHT routing addresses when it becomes NotReachable":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, Port, MappingProtocol)))

    autorelayservice.setup(autoRelay, sw)

    # Reachable: the node announces direct addresses, including UDP for the DHT.
    await mapper.handleNatStatus(
      Reachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )
    check disc.discoveryAddrs.len > 0

    # NotReachable: the DHT routing addresses are cleared
    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )
    check disc.discoveryAddrs.len == 0

  test "announceRelayReservation announces only the publicly dialable circuit address":
    disc.announceRelayReservation(
      @[circuitAddr("127.0.0.1"), circuitAddr("204.168.234.45")]
    )

    check disc.providerAddrs == @[circuitAddr("204.168.234.45")]

  test "announceRelayReservation does not announce a private circuit address":
    disc.announceRelayReservation(@[circuitAddr("127.0.0.1")])

    check disc.providerAddrs.len == 0

proc mapperWith(protocol: MappingProtocol): Option[NatPortMapper] =
  some(NatPortMapper(portMapping: some(PortMapping(activeMappingProtocol: protocol))))

asyncchecksuite "NAT - portMappingStr":
  test "no mapper is none":
    check portMappingStr(none(NatPortMapper)) == "none"

  test "mapper without an active protocol is none":
    check portMappingStr(some(NatPortMapper())) == "none"

  test "UPnP maps to upnp":
    check portMappingStr(mapperWith(MappingProtocol.UPnP)) == "upnp"

  test "NAT-PMP maps to pmp":
    check portMappingStr(mapperWith(MappingProtocol.NatPmp)) == "pmp"

  test "PCP maps to pcp":
    check portMappingStr(mapperWith(MappingProtocol.PCP)) == "pcp"

  test "Direct maps to direct":
    check portMappingStr(mapperWith(MappingProtocol.Direct)) == "direct"

  test "Unknown maps to none":
    check portMappingStr(mapperWith(MappingProtocol.Unknown)) == "none"

asyncchecksuite "NAT - mapNatPorts":
  test "returns the mapped ports when both mappings succeed":
    let mapper = MockMapNatPortMapper(
      tcpResult: mappingOk(cint(1), 9000), udpResult: mappingOk(cint(2), 9001)
    )

    check (await mapper.mapNatPorts()) ==
      some((Port(9000), Port(9001), MappingProtocol.UPnP))
    check mapper.destroyed.len == 0

  test "destroys the TCP mapping when the UDP mapping fails":
    let mapper = MockMapNatPortMapper(
      tcpResult: mappingOk(cint(42), 9000),
      udpResult: Result[MappingResult, string].err("udp mapping failed"),
    )

    check (await mapper.mapNatPorts()).isNone
    check mapper.destroyed == @[cint(42)]

  test "gives up without touching UDP when the TCP mapping fails":
    let mapper = MockMapNatPortMapper(
      tcpResult: Result[MappingResult, string].err("tcp mapping failed"),
      udpResult: mappingOk(cint(2), 9001),
    )

    check (await mapper.mapNatPorts()).isNone
    check mapper.createAttempts == @[PlumProtocol.TCP] # UDP never attempted
    check mapper.destroyed.len == 0 # nothing to clean up

  test "does not map when configured with an external IP":
    let mapper = MockMapNatPortMapper(
      natConfig: nat.NatConfig(hasExtIp: true, extIp: parseIpAddress("1.2.3.4"))
    )

    check (await mapper.mapNatPorts()).isNone
    check mapper.createAttempts.len == 0 # short-circuits before any mapping

  test "reuses the existing mapping when both are still live":
    privateAccess(PortMapping)
    let mapper = MockMapNatPortMapper(live: true)
    mapper.portMapping = some(
      PortMapping(
        tcpMappingId: cint(1),
        udpMappingId: cint(2),
        activeMappingProtocol: MappingProtocol.UPnP,
        activeTcpPort: Port(9000),
        activeUdpPort: Port(9001),
      )
    )

    check (await mapper.mapNatPorts()) ==
      some((Port(9000), Port(9001), MappingProtocol.UPnP))
    check mapper.createAttempts.len == 0

  test "does not map after stop, maps again after start":
    let mapper = MockMapNatPortMapper(
      tcpResult: mappingOk(cint(1), 9000), udpResult: mappingOk(cint(2), 9001)
    )

    mapper.stop()

    check (await mapper.mapNatPorts()).isNone
    check mapper.createAttempts.len == 0

    mapper.start()

    check (await mapper.mapNatPorts()) ==
      some((Port(9000), Port(9001), MappingProtocol.UPnP))
