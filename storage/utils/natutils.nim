{.push raises: [].}

import std/[net, tables, hashes, options], pkg/results, chronos, chronicles

import pkg/libp2p

type NatStrategy* = enum
  NatAny
  NatUpnp
  NatPmp

func isGlobalUnicast*(address: TransportAddress): bool =
  if address.isGlobal() and address.isUnicast(): true else: false

func isGlobalUnicast*(address: IpAddress): bool =
  let a = initTAddress(address, Port(0))
  a.isGlobalUnicast()

proc getRoute(publicAddress: TransportAddress): Result[IpAddress, cstring] =
  let route = getBestRoute(publicAddress)

  if route.source.family == AddressFamily.None or route.source.isUnspecified():
    err("No best route found")
  else:
    let ip =
      try:
        route.source.address()
      except ValueError as e:
        # This should not occur really.
        error "Address conversion error", exception = e.name, msg = e.msg
        return err("Invalid IP address")
    ok(ip)

proc getRouteIpv4*(): Result[IpAddress, cstring] =
  # Avoiding Exception with initTAddress and can't make it work with static.
  # Note: `publicAddress` is only used an "example" IP to find the best route,
  # no data is send over the network to this IP!
  let publicAddress = TransportAddress(
    family: AddressFamily.IPv4, address_v4: [1'u8, 1, 1, 1], port: Port(0)
  )

  return getRoute(publicAddress)

proc getRouteIpv6*(): Result[IpAddress, cstring] =
  # Note: `googleDnsIpv6` is only used as an "example" IP to find the best route,
  # no data is sent over the network to this IP!
  const googleDnsIpv6 = TransportAddress(
    family: AddressFamily.IPv6,
    # 2001:4860:4860::8888
    address_v6: [32'u8, 1, 72, 96, 72, 96, 0, 0, 0, 0, 0, 0, 0, 0, 136, 136],
    port: Port(0),
  )

  return getRoute(googleDnsIpv6)

# If bindIp is a anyLocal address (0.0.0.0 or ::),
# the function will find the best ip address.
# Otherwise, it will just return the ip as it is.
proc getBestLocalAddress*(bindIp: IpAddress): Option[IpAddress] =
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
