## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/strutils
import std/options
import std/net

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ./port_mapping

proc getAddressAndPort*(
    ma: MultiAddress
): tuple[ip: IpAddress, port: MappingPort] {.raises: [ValueError].} =
  try:
    # Try IPv4 first
    let ipv4Result = ma[multiCodec("ip4")]
    let ip =
      if ipv4Result.isOk:
        let ipBytes = ipv4Result.get().protoArgument().expect("Invalid IPv4 format")
        let ipArray = [ipBytes[0], ipBytes[1], ipBytes[2], ipBytes[3]]
        IpAddress(family: IPv4, address_v4: ipArray)
      else:
        # Try IPv6 if IPv4 not found
        let ipv6Result = ma[multiCodec("ip6")]
        if ipv6Result.isOk:
          let ipBytes = ipv6Result.get().protoArgument().expect("Invalid IPv6 format")
          var ipArray: array[16, byte]
          for i in 0 .. 15:
            ipArray[i] = ipBytes[i]
          IpAddress(family: IPv6, address_v6: ipArray)
        else:
          raise newException(ValueError, "Unknown IP family")

    # Get TCP Port
    let tcpPortResult = ma[multiCodec("tcp")]
    if tcpPortResult.isOk:
      let tcpPortBytes =
        tcpPortResult.get().protoArgument().expect("Invalid port format")
      let tcpPort = newTcpMappingPort(Port(fromBytesBE(uint16, tcpPortBytes)))
      return (ip: ip, port: tcpPort)

    # Get UDP Port
    let udpPortResult = ma[multiCodec("udp")]
    if udpPortResult.isOk:
      let udpPortBytes =
        udpPortResult.get().protoArgument().expect("Invalid port format")
      let udpPort = newUdpMappingPort(Port(fromBytesBE(uint16, udpPortBytes)))
      return (ip: ip, port: udpPort)

    raise newException(ValueError, "No TCP/UDP port specified")
  except Exception:
    raise newException(ValueError, "Invalid multiaddr")

proc getMultiAddr*(ip: IpAddress, port: MappingPort): MultiAddress =
  let ipFamily = if ip.family == IpAddressFamily.IPv4: "/ip4/" else: "/ip6/"
  let portType = if (internalPort is TcpPort): "/tcp/" else: "/udp/"
  return MultiAddress.init(ipFamily & $ip & portType & $(port.value)).expect(
      "valid multiaddr"
    )
