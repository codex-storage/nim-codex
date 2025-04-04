{.push raises: [].}

import
  std/[tables, hashes], pkg/results, pkg/stew/shims/net as stewNet, chronos, chronicles

import pkg/libp2p

type NatStrategy* = enum
  NatAny
  NatUpnp
  NatPmp
  NatNone

type IpLimits* = object
  limit*: uint
  ips: Table[IpAddress, uint]

func hash*(ip: IpAddress): Hash =
  case ip.family
  of IpAddressFamily.IPv6:
    hash(ip.address_v6)
  of IpAddressFamily.IPv4:
    hash(ip.address_v4)

func inc*(ipLimits: var IpLimits, ip: IpAddress): bool =
  let val = ipLimits.ips.getOrDefault(ip, 0)
  if val < ipLimits.limit:
    ipLimits.ips[ip] = val + 1
    true
  else:
    false

func dec*(ipLimits: var IpLimits, ip: IpAddress) =
  let val = ipLimits.ips.getOrDefault(ip, 0)
  if val == 1:
    ipLimits.ips.del(ip)
  elif val > 1:
    ipLimits.ips[ip] = val - 1

func isGlobalUnicast*(address: TransportAddress): bool =
  if address.isGlobal() and address.isUnicast(): true else: false

func isGlobalUnicast*(address: IpAddress): bool =
  let a = initTAddress(address, Port(0))
  a.isGlobalUnicast()

proc getRouteIpv4*(): Result[IpAddress, cstring] =
  # Avoiding Exception with initTAddress and can't make it work with static.
  # Note: `publicAddress` is only used an "example" IP to find the best route,
  # no data is send over the network to this IP!
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
        # This should not occur really.
        error "Address conversion error", exception = e.name, msg = e.msg
        return err("Invalid IP address")
    ok(ip)
