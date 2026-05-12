import std/[net, importutils, envvars]
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

privateAccess(NatMapper)

type MockUpnpDevice = ref object of UpnpDevice
  deletedPorts: seq[(Port, NatIpProtocol)]

method discover*(d: MockUpnpDevice): Result[int, cstring] {.gcsafe.} =
  ok(1)

method selectIGD*(d: MockUpnpDevice): SelectIGDResult {.gcsafe.} =
  IGDFound

method deletePortMapping*(
    d: MockUpnpDevice, port: Port, proto: NatIpProtocol
): Result[void, string] {.gcsafe.} =
  d.deletedPorts.add((port, proto))
  ok()

type MockNatMapper = ref object of NatMapper
  mappedPorts: Option[(Port, Port)]

method mapNatPorts*(
    m: MockNatMapper
): Future[Option[(Port, Port)]] {.async: (raises: [CancelledError]), gcsafe.} =
  m.mappedPorts

suite "NAT - NatMapper.close":
  test "does nothing when no upnp mapping":
    let mapper = MockNatMapper(
      natConfig: NatConfig(hasExtIp: false, nat: NatAuto),
      tcpPort: Port(8080),
      discoveryPort: Port(8090),
    )
    let device = MockUpnpDevice()
    mapper.close(device)
    check device.deletedPorts.len == 0

  test "deletes tcp and udp ports when upnp mapping exists":
    let mapper = MockNatMapper(
      natConfig: NatConfig(hasExtIp: false, nat: NatAuto),
      tcpPort: Port(8080),
      discoveryPort: Port(8090),
    )
    mapper.hasUpnpMapping = true
    let device = MockUpnpDevice()
    mapper.close(device)
    check device.deletedPorts ==
      @[(Port(8080), NatIpProtocol.Tcp), (Port(8090), NatIpProtocol.Udp)]

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
    let mapper = MockNatMapper(mappedPorts: some((Port(9000), Port(9001))))

    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check disc.announceAddrs ==
      @[MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")]
    check not autoRelay.isRunning

  test "handleNatStatus starts autoRelay when NotReachable and UPnP failed":
    let mapper = MockNatMapper(mappedPorts: none((Port, Port)))

    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning

  test "handleNatStatus starts autoRelay when NotReachable and mapping fails":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatMapper(mappedPorts: none((Port, Port)))

    await mapper.handleNatStatus(
      NotReachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check disc.announceAddrs == newSeq[MultiAddress]()

  test "handleNatStatus does not announce address when Reachable and no dialBackAddr":
    let mapper = MockNatMapper(mappedPorts: none((Port, Port)))

    await mapper.handleNatStatus(
      Reachable, Opt.none(MultiAddress), discoveryPort, disc, sw, autoRelay
    )

    check disc.announceAddrs == newSeq[MultiAddress]()
    check not autoRelay.isRunning

  test "handleNatStatus stops relay and announces dialBackAddr when Reachable":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatMapper(mappedPorts: none((Port, Port)))

    discard await autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(
      Reachable, Opt.some(dialBack), discoveryPort, disc, sw, autoRelay
    )

    check not autoRelay.isRunning
    check disc.announceAddrs == @[dialBack]

suite "NAT - UPnP port mapping (requires NAT_TEST_UPNP=1)":
  test "mapPorts and cleanup":
    if getEnv("NAT_TEST_UPNP") != "1":
      skip()
      return

    let res = UpnpDevice.init()
    check res.isOk

    let device = res.value
    let ports = device.mapPorts(Port(8101), Port(8090))
    check ports.isSome

    let (tcp, udp) = ports.get()
    check tcp == Port(8101)
    check udp == Port(8090)

    check device.deletePortMapping(Port(8101), NatIpProtocol.Tcp).isOk
    check device.deletePortMapping(Port(8090), NatIpProtocol.Udp).isOk
