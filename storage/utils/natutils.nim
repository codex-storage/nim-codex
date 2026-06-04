{.push raises: [].}

import std/[net, options], pkg/results, chronos, chronicles

import pkg/libp2p

type NatStrategy* = enum
  NatAuto
  NatUpnp
  NatPmp

proc getRouteIpv4*(): Result[IpAddress, cstring] =
  let
    publicAddress = TransportAddress(
      family: AddressFamily.IPv4, address_v4: [1'u8, 1, 1, 1], port: Port(0)
    )
    route = getBestRoute(publicAddress)

  if route.source.isUnspecified():
    err("No best ipv4 route found")
  else:
    let ip =
      try:
        route.source.address()
      except ValueError as e:
        error "Address conversion error", exception = e.name, msg = e.msg
        return err("Invalid IP address")
    ok(ip)

proc getRouteIpv6*(): Result[IpAddress, cstring] =
  const googleDnsIpv6 = TransportAddress(
    family: AddressFamily.IPv6,
    address_v6: [32'u8, 1, 72, 96, 72, 96, 0, 0, 0, 0, 0, 0, 0, 0, 136, 136],
    port: Port(0),
  )
  let route = getBestRoute(googleDnsIpv6)
  if route.source.isUnspecified():
    return err("No best ipv6 route found")
  try:
    ok(route.source.address())
  except ValueError as e:
    error "Address conversion error", exception = e.name, msg = e.msg
    err("Invalid IP address")

proc getBestLocalAddress*(bindIp: IpAddress): Option[IpAddress] =
  ## If bindIp is anyLocal (0.0.0.0 or ::), finds the best local IP via routing table.
  ## Otherwise returns bindIp as-is.
  let bindAddress = initTAddress(bindIp, Port(0))
  if bindAddress.isAnyLocal():
    let ip =
      if bindIp.family == IpAddressFamily.IPv6:
        getRouteIpv6()
      else:
        getRouteIpv4()
    if ip.isOk():
      return some(ip.get())
    return none(IpAddress)
  else:
    return some(bindIp)
