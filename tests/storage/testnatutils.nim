import std/[options, net]
import nat_traversal/[miniupnpc, natpmp]
import pkg/results
import ../asynctest
import ../../storage/utils/natutils

type MockUpnpDev = ref object of UpnpDevice
  discoverOk: bool
  igdResult: SelectIGDResult
  addPortMappingOk: bool
  failOnProto: Option[NatIpProtocol]

type MockPmpDev = ref object of PmpDevice
  addPortMappingOk: bool
  mappedPort: Port

method discover*(d: MockUpnpDev): Result[int, cstring] {.gcsafe.} =
  if d.discoverOk:
    ok(1)
  else:
    err(cstring("discover failed"))

method selectIGD*(d: MockUpnpDev): SelectIGDResult {.gcsafe.} =
  d.igdResult

method addPortMapping*(
    d: MockUpnpDev, port: Port, proto: NatIpProtocol
): Result[Port, string] {.gcsafe.} =
  if d.failOnProto == some(proto):
    err("mapping failed")
  elif d.addPortMappingOk:
    ok(port)
  else:
    err("mapping failed")

method getSpecificPortMapping*(
    d: MockUpnpDev, externalPort: string, protocol: UPNPProtocol
): Result[PortMappingRes, cstring] {.gcsafe.} =
  ok(PortMappingRes())

method addPortMapping*(
    d: MockPmpDev, port: Port, proto: NatIpProtocol
): Result[Port, string] {.gcsafe.} =
  if d.addPortMappingOk:
    ok(d.mappedPort)
  else:
    err("mapping failed")

suite "NAT - UpnpDevice.init":
  test "returns err when discover fails":
    check MockUpnpDev(discoverOk: false).init().isErr

  test "returns err when IGD not found":
    check MockUpnpDev(discoverOk: true, igdResult: IGDNotFound).init().isErr

  test "returns ok when IGD found":
    check MockUpnpDev(discoverOk: true, igdResult: IGDFound).init().isOk

  test "returns ok when IGD not connected":
    check MockUpnpDev(discoverOk: true, igdResult: IGDNotConnected).init().isOk

  test "returns ok when not an IGD":
    check MockUpnpDev(discoverOk: true, igdResult: NotAnIGD).init().isOk

  test "returns ok when IP not routable":
    check MockUpnpDev(discoverOk: true, igdResult: IGDIpNotRoutable).init().isOk

suite "NAT - UpnpDevice.mapPorts":
  test "returns none when addPortMapping fails":
    check MockUpnpDev(addPortMappingOk: false).mapPorts(Port(8080), Port(8090)).isNone

  test "returns mapped ports":
    let res = MockUpnpDev(addPortMappingOk: true).mapPorts(Port(8080), Port(8090))
    check res.isSome
    check res.get() == (Port(8080), Port(8090))

  test "returns none when tcp mapping fails":
    let d = MockUpnpDev(addPortMappingOk: true, failOnProto: some(NatIpProtocol.Tcp))
    check d.mapPorts(Port(8080), Port(8090)).isNone

  test "returns none when udp mapping fails":
    let d = MockUpnpDev(addPortMappingOk: true, failOnProto: some(NatIpProtocol.Udp))
    check d.mapPorts(Port(8080), Port(8090)).isNone

suite "NAT - PmpDevice.mapPorts":
  test "returns none when mapping fails":
    check MockPmpDev(addPortMappingOk: false).mapPorts(Port(8080), Port(8090)).isNone

  test "returns assigned external ports":
    let d = MockPmpDev(addPortMappingOk: true, mappedPort: Port(9000))
    let res = d.mapPorts(Port(8080), Port(8090))
    check res.isSome
    check res.get() == (Port(9000), Port(9000))
