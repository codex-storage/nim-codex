# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[options, strutils, net]

import pkg/nat_traversal/[miniupnpc, natpmp]
import pkg/json_serialization/std/net
import pkg/results
import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/chronicles
import pkg/libp2p

import ../utils

logScope:
  topics = "codex nat port-mapping"

const
  UPNP_TIMEOUT = 200 # ms
  RENEWAL_SLEEP = (20 * 60).seconds
  Pmp_LIFETIME = 60 * 60 # in seconds, must be longer than RENEWAL_INTERVAL
  MAPPING_DESCRIPTION = "codex"

type PortMappingStrategy* = enum
  Any
  Upnp
  Pmp
  None

type MappingPort* = ref object of RootObj
  value*: Port

proc `$`*(p: MappingPort): string =
  $(p.value)

type TcpPort* = ref object of MappingPort
type UdpPort* = ref object of MappingPort

proc newTcpMappingPort*(value: Port): TcpPort =
  TcpPort(value: value)

proc newUdpMappingPort*(value: Port): UdpPort =
  UdpPort(value: value)

type PortMappingEntry* =
  tuple[internalPort: MappingPort, externalPort: Option[MappingPort]]

type PortMapping* = ref object of RootObj
  upnp: Miniupnp
  npmp: NatPmp
  mappings: seq[PortMappingEntry]
  renewalLoop: Future[void]

proc initUpnp(self: PortMapping) =
  logScope:
    protocol = "upnp"

  if not self.upnp.isNil:
    warn "UPnP already initialized!"

  self.upnp = newMiniupnp()
  self.upnp.discoverDelay = UPNP_TIMEOUT

  if err =? self.upnp.discover().errorOption:
    warn "UPnP error discoverning Internet Gateway Devices", msg = err
    self.upnp = nil

  case self.upnp.selectIGD()
  of IGDNotFound:
    info "UPnP Internet Gateway Device not found. Giving up."
    self.upnp = nil
      # As UPnP is not supported on our network we won't be using it --> lets erase it.
  of IGDFound:
    info "UPnP Internet Gateway Device found."
  of IGDNotConnected:
    info "UPnP Internet Gateway Device found but it's not connected. Trying anyway."
  of NotAnIGD:
    info "Some device found, but it's not recognised as an Internet Gateway Device. Trying anyway."
  of IGDIpNotRoutable:
    info "UPnP Internet Gateway Device found and is connected, but with a reserved or non-routable IP. Trying anyway."

proc initNpmp(self: PortMapping) =
  logScope:
    protocol = "npmp"

  if not self.npmp.isNil:
    warn "NAT-PMP already initialized!"

  self.npmp = newNatPmp()

  if err =? self.npmp.init().errorOption:
    warn "Error initialization of NAT-PMP", msg = err
    self.npmp = nil

  if err =? self.npmp.externalIPAddress().errorOption:
    warn "Fetching of external IP failed.", msg = err
    self.npmp = nil

  info "NAT-PMP initialized"

## Try to initilize all the port mapping protocols based on what is available on the network
proc initProtocols(self: PortMapping, strategy: PortMappingStrategy) =
  if strategy == PortMappingStrategy.Any or strategy == PortMappingStrategy.Upnp:
    self.initUpnp()

    if not self.upnp.isNil:
      return # UPnP is available, using that, no need for NAT-PMP.

  if strategy == PortMappingStrategy.Any or strategy == PortMappingStrategy.Pmp:
    self.initNpmp()

proc new*(T: type PortMapping, strategy: PortMappingStrategy): PortMapping =
  let mapping = PortMapping(upnp: nil, npmp: nil, mappings: @[])
  mapping.initProtocols(strategy)

  return mapping

proc upnpPortMapping(
    self: PortMapping, internalPort: MappingPort, externalPort: MappingPort
): ?!MappingPort =
  let protocol = if (internalPort is TcpPort): UPNPProtocol.TCP else: UPNPProtocol.UDP

  logScope:
    protocol = "upnp"
    externalPort = externalPort.value
    internalPort = internalPort.value
    protocol = protocol

  let pmres = self.upnp.addPortMapping(
    externalPort = $(externalPort.value),
    protocol = protocol,
    internalHost = self.upnp.lanAddr,
    internalPort = $(internalPort.value),
    desc = MAPPING_DESCRIPTION,
    leaseDuration = 0,
  )

  if pmres.isErr:
    error "UPnP port mapping", msg = pmres.error
    return failure($pmres.error)

  # let's check it
  let cres = self.upnp.getSpecificPortMapping(
    externalPort = $(externalPort.value), protocol = protocol
  )
  if cres.isErr:
    warn "UPnP port mapping check failed. Assuming the check itself is broken and the port mapping was done.",
      msg = cres.error
  info "UPnP added port mapping"

  return success(externalPort)

proc npmpPortMapping(
    self: PortMapping, internalPort: MappingPort, externalPort: MappingPort
): ?!MappingPort =
  let protocol =
    if (internalPort is TcpPort): NatPmpProtocol.TCP else: NatPmpProtocol.UDP

  logScope:
    protocol = "npmp"
    externalPort = externalPort.value
    internalPort = internalPort.value
    protocol = protocol

  let extPortRes = self.npmp.addPortMapping(
    eport = externalPort.value.cushort,
    iport = internalPort.value.cushort,
    protocol = protocol,
    lifetime = Pmp_LIFETIME,
  )

  if extPortRes.isErr:
    error "NAT-PMP port mapping error", msg = extPortRes.error()
    return failure(extPortRes.error())

  info "NAT-PMP: added port mapping"

  if internalPort is TcpPort:
    return success(MappingPort(newTcpMappingPort(Port(extPortRes.value))))
  else:
    return success(MappingPort(newUdpMappingPort(Port(extPortRes.value))))

## Create port mapping that will try to utilize the same port number
## of the internal port for the external port mapping.
##
## TODO: Add support for trying mapping of random external port.

proc doPortMapping(self: PortMapping, port: MappingPort): ?!MappingPort =
  if not self.upnp.isNil:
    return self.upnpPortMapping(port, port)

  if not self.npmp.isNil:
    return self.npmpPortMapping(port, port)

  return failure("No active startegy")

proc doPortMapping(
    self: PortMapping, internalPort: MappingPort, externalPort: MappingPort
): ?!MappingPort =
  if not self.upnp.isNil:
    return self.upnpPortMapping(internalPort, externalPort)

  if not self.npmp.isNil:
    return self.npmpPortMapping(internalPort, externalPort)

  return failure("No active startegy")

proc renewPortMapping(self: PortMapping) {.async.} =
  while true:
    for mapping in self.mappings:
      if externalPort =? mapping.externalPort:
        without renewedExternalPort =?
          self.doPortMapping(mapping.internalPort, externalPort), err:
          error "Error while renewal of port mapping", msg = err.msg

        if renewedExternalPort.value != externalPort.value:
          error "The renewed external port is not the same as the originally mapped"

    await sleepAsync(RENEWAL_SLEEP)

## Gets external IP provided by the port mapping protocols
## Port mapping needs to be succesfully started first using `startPortMapping()`
proc getExternalIP*(self: PortMapping): ?IpAddress =
  if self.upnp.isNil and self.npmp.isNil:
    warn "No available port-mapping protocol"
    return IpAddress.none

  if not self.upnp.isNil:
    let ires = self.upnp.externalIPAddress
    if ires.isOk():
      info "Got externa IP address", ip = ires.value
      try:
        return parseIpAddress(ires.value).some
      except ValueError as e:
        error "Failed to parse IP address", err = e.msg
    else:
      debug "Getting external IP address using UPnP failed",
        msg = ires.error, protocol = "upnp"

  if not self.npmp.isNil:
    let nires = self.npmp.externalIPAddress()
    if nires.isErr:
      debug "Getting external IP address using NAT-PMP failed", msg = nires.error
    else:
      try:
        info "Got externa IP address", ip = $(nires.value), protocol = "npmp"
        return parseIpAddress($(nires.value)).some
      except ValueError as e:
        error "Failed to parse IP address", err = e.msg

  return IpAddress.none

## Returns true if some supported port mapping protocol
## is available on the local network
proc isAvailable*(self: PortMapping): bool =
  return (not self.upnp.isNil) or (not self.npmp.isNil)

proc start*(
    self: PortMapping, internalPorts: seq[MappingPort]
): Future[?!seq[PortMappingEntry]] {.async: (raises: [CancelledError]).} =
  if internalPorts.len == 0:
    return failure("No internal ports to be mapped were supplied")

  if not self.isAvailable():
    return failure("No available port mapping protocols on the network")

  if self.mappings.len > 0:
    return failure("Port mapping was already started! Stop first before re-starting.")

  for port in internalPorts:
    without mappedPort =? self.doPortMapping(port), err:
      warn "Failed to map port", port = port, msg = err.msg
      self.mappings.add((internalPort: port, externalPort: MappingPort.none))

    self.mappings.add((internalPort: port, externalPort: mappedPort.some))

  self.renewalLoop = self.renewPortMapping()
  asyncSpawn(self.renewalLoop)

  return success(self.mappings)

proc stop*(self: PortMapping) {.async: (raises: [CancelledError]).} =
  if self.upnp.isNil or self.npmp.isNil:
    debug "Port mapping is not running, nothing to stop"
    return

  info "Stopping port mapping renewal loop"
  if not self.renewalLoop.isNil:
    if not self.renewalLoop.finished:
      try:
        await self.renewalLoop.cancelAndWait()
      except CancelledError:
        discard
      except CatchableError as e:
        error "Error during cancellation of renewal loop", msg = e.msg

    self.renewalLoop = nil

  for mapping in self.mappings:
    if mapping.externalPort.isNone:
      continue

    if not self.upnp.isNil:
      let protocol =
        if (mapping.internalPort is TcpPort): UPNPProtocol.TCP else: UPNPProtocol.UDP

      if err =?
          self.upnp.deletePortMapping(
            externalPort = $((!mapping.externalPort).value), protocol = protocol
          ).errorOption:
        error "UPnP port mapping deletion error", msg = err
      else:
        debug "UPnP: deleted port mapping",
          externalPort = !mapping.externalPort,
          internalPort = mapping.internalPort,
          protocol = protocol

    if not self.npmp.isNil:
      let protocol =
        if (mapping.internalPort is TcpPort): NatPmpProtocol.TCP else: NatPmpProtocol.UDP

      if err =?
          self.npmp.deletePortMapping(
            eport = (!mapping.externalPort).value.cushort,
            iport = mapping.internalPort.value.cushort,
            protocol = protocol,
          ).errorOption:
        error "NAT-PMP port mapping deletion error", msg = err
      else:
        debug "NAT-PMP: deleted port mapping",
          externalPort = !mapping.externalPort,
          internalPort = mapping.internalPort,
          protocol = protocol

  self.mappings = @[]
