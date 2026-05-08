{.push raises: [].}

import std/[options, net]
import nat_traversal/[miniupnpc, natpmp]
import pkg/chronicles
import results

export miniupnpc, natpmp, results, options, net

logScope:
  topics = "nat"

const UPNP_TIMEOUT* = 200 # ms
const NATPMP_LIFETIME* = 60 * 60 # seconds

type NatStrategy* = enum
  NatAuto

type NatIpProtocol* = enum
  Tcp
  Udp

# Generic Nat device can be UPnP or PmP
type NatDevice* = ref object of RootObj

type UpnpDevice* = ref object of NatDevice
  upnp: Miniupnp

type PmpDevice* = ref object of NatDevice
  npmp: NatPmp

# appPortMapping is specific to the type of Nat device
method addPortMapping*(
    d: NatDevice, port: Port, proto: NatIpProtocol
): Result[Port, string] {.base, gcsafe.} =
  return err("not implemented")

# Creates the mapping the the router and
# returns the opened ports.
method mapPorts*(
    d: NatDevice, tcpPort, udpPort: Port
): Option[(Port, Port)] {.base, gcsafe.} =
  var extTcpPort, extUdpPort: Port

  for t in [(tcpPort, NatIpProtocol.Tcp), (udpPort, NatIpProtocol.Udp)]:
    let (port, proto) = t
    let pmres = d.addPortMapping(port, proto)

    if pmres.isErr:
      error "port mapping failed", msg = pmres.error
      return none((Port, Port))

    case proto
    of Tcp:
      extTcpPort = pmres.value
    of Udp:
      extUdpPort = pmres.value

  return some((extTcpPort, extUdpPort))

method getSpecificPortMapping*(
    d: UpnpDevice, externalPort: string, protocol: UPNPProtocol
): Result[PortMappingRes, cstring] {.base, gcsafe.} =
  if d.upnp == nil:
    return err(cstring("upnp not initialized"))

  d.upnp.getSpecificPortMapping(externalPort = externalPort, protocol = protocol)

method discover*(d: UpnpDevice): Result[int, cstring] {.base, gcsafe.} =
  if d.upnp == nil:
    return err(cstring("upnp not initialized"))

  return d.upnp.discover()

method selectIGD*(d: UpnpDevice): SelectIGDResult {.base, gcsafe.} =
  if d.upnp == nil:
    return IGDNotFound

  return d.upnp.selectIGD()

proc init*(T: type UpnpDevice): Result[UpnpDevice, string] {.gcsafe.} =
  UpnpDevice().init()

# Init UPnP device and create miniupnp instance.
# It call "discover" to retrieve the UPnP devices on the network,
# and then "selectIGD" to select a suitable device.
proc init*(d: UpnpDevice): Result[UpnpDevice, string] {.gcsafe.} =
  if d.upnp == nil:
    d.upnp = newMiniupnp()

  d.upnp.discoverDelay = UPNP_TIMEOUT

  let dres = d.discover()
  if dres.isErr:
    debug "UPnP", msg = dres.error
    return err($dres.error)

  case d.selectIGD()
  of IGDNotFound:
    debug "UPnP", msg = "Internet Gateway Device not found. Giving up."
    return err("IGD not found")
  of IGDFound:
    debug "UPnP", msg = "Internet Gateway Device found."
  of IGDNotConnected:
    debug "UPnP",
      msg = "Internet Gateway Device found but it's not connected. Trying anyway."
  of NotAnIGD:
    debug "UPnP",
      msg =
        "Some device found, but it's not recognised as an Internet Gateway Device. Trying anyway."
  of IGDIpNotRoutable:
    debug "UPnP",
      msg =
        "Internet Gateway Device found and is connected, but with a reserved or non-routable IP. Trying anyway."

  return ok(d)

# For UPnP, the external port is the same as the application port.
# This should work for most of the case.
# We could change this by using addAnyPortMapping for IGD2 compatible routers
# if needed.
method addPortMapping*(
    d: UpnpDevice, port: Port, proto: NatIpProtocol
): Result[Port, string] {.gcsafe.} =
  if d.upnp == nil:
    return err("upnp not initialized")

  let protocol = if proto == NatIpProtocol.Tcp: UPNPProtocol.TCP else: UPNPProtocol.UDP
  let pmres = d.upnp.addPortMapping(
    externalPort = $port,
    protocol = protocol,
    internalHost = d.upnp.lanAddr,
    internalPort = $port,
    desc = "logos-storage",
    leaseDuration = 0,
  )
  if pmres.isErr:
    return err($pmres.error)

  let cres = d.getSpecificPortMapping(externalPort = $port, protocol = protocol)
  if cres.isErr:
    # Eventually, the check could fail on some router even if the router is successful.
    # So we log a warning but we still want to continue because it is not sure it is a failure.
    warn "UPnP port mapping check failed. Assuming the check itself is broken and the port mapping was done.",
      msg = cres.error

  info "UPnP: added port mapping", externalPort = port, internalPort = port

  return ok(port)

method deletePortMapping*(
    d: UpnpDevice, port: Port, proto: NatIpProtocol
): Result[void, string] {.base, gcsafe.} =
  if d.upnp == nil:
    return err("upnp not initialized")

  let protocol = if proto == NatIpProtocol.Tcp: UPNPProtocol.TCP else: UPNPProtocol.UDP
  let res = d.upnp.deletePortMapping(externalPort = $port, protocol = protocol)
  if res.isErr:
    return err($res.error)

  debug "UPnP: deleted port mapping", port, proto

  ok()

proc init*(T: type PmpDevice): Result[PmpDevice, string] {.gcsafe.} =
  PmpDevice().init()

# Create a NatPmP instance.
proc init*(d: PmpDevice): Result[PmpDevice, string] {.gcsafe.} =
  if d.npmp == nil:
    d.npmp = newNatPmp()

  let res = d.npmp.init()
  if res.isErr:
    debug "NAT-PMP", msg = res.error
    return err($res.error)

  return ok(d)

# Add a port mapping on NAT-PMP device.
# The application port might not be the external port.
# The latter is returned.
method addPortMapping*(
    d: PmpDevice, port: Port, proto: NatIpProtocol
): Result[Port, string] {.gcsafe.} =
  if d.npmp == nil:
    return err("npmp not initialized")

  let protocol =
    if proto == NatIpProtocol.Tcp: NatPmpProtocol.TCP else: NatPmpProtocol.UDP
  let pmres = d.npmp.addPortMapping(
    eport = port.cushort,
    iport = port.cushort,
    protocol = protocol,
    lifetime = NATPMP_LIFETIME,
  )
  if pmres.isErr:
    return err(pmres.error)

  let extPort = Port(pmres.value)

  info "NAT-PMP: added port mapping", externalPort = extPort, internalPort = port

  return ok(extPort)
