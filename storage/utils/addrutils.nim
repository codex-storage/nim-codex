## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/net
import std/strutils
import std/options

import pkg/libp2p

func remapAddr*(
    address: MultiAddress,
    ip: Option[IpAddress] = IpAddress.none,
    port: Option[Port] = Port.none,
    protocol: Option[string] = string.none,
): MultiAddress =
  ## Remap addresses to new IP, port, and/or transport protocol (e.g. "tcp" → "udp")
  ##
  ## Assumes a /ip4|ip6/<ip>/tcp|udp/<port> address: anything else crashes (Defect).

  var parts = ($address).split("/")

  parts[2] =
    if ip.isSome:
      $ip.get
    else:
      parts[2]

  parts[3] =
    if protocol.isSome:
      protocol.get
    else:
      parts[3]

  parts[4] =
    if port.isSome:
      $port.get
    else:
      parts[4]

  MultiAddress.init(parts.join("/")).expect("Should construct multiaddress")

proc getMultiAddrWithIPAndUDPPort*(ip: IpAddress, port: Port): MultiAddress =
  ## Creates a MultiAddress with the specified IP address and UDP port
  ## 
  ## Parameters:
  ##   - ip: A valid IP address (IPv4 or IPv6)
  ##   - port: The UDP port number
  ##
  ## Returns:
  ##   A MultiAddress in the format "/ip4/<address>/udp/<port>" or "/ip6/<address>/udp/<port>"

  let ipFamily = if ip.family == IpAddressFamily.IPv4: "/ip4/" else: "/ip6/"
  return MultiAddress.init(ipFamily & $ip & "/udp/" & $port).expect("valid multiaddr")

func getTcpPort*(ma: MultiAddress): Option[Port] =
  let parts = ($ma).split("/")
  for i, part in parts:
    if part == "tcp" and i + 1 < parts.len:
      try:
        return some(Port(parseInt(parts[i + 1])))
      except ValueError:
        return Port.none
  Port.none

proc getMultiAddrWithIpAndTcpPort*(ip: IpAddress, port: Port): MultiAddress =
  ## Creates a MultiAddress with the specified IP address and TCP port
  ## 
  ## Parameters:
  ##   - ip: A valid IP address (IPv4 or IPv6)
  ##   - port: The TCP port number
  ##
  ## Returns:
  ##   A MultiAddress in the format "/ip4/<address>/tcp/<port>" or "/ip6/<address>/tcp/<port>"

  let ipFamily = if ip.family == IpAddressFamily.IPv4: "/ip4/" else: "/ip6/"
  return MultiAddress.init(ipFamily & $ip & "/tcp/" & $port).expect(
      "Failed to construct multiaddress with IP and TCP port"
    )
