# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[options, os, strutils, times, net, atomics]

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
  RENEWAL_INTERVAL = 20 * 60 # seconds
  Pmp_LIFETIME = 60 * 60 # in seconds, must be longer than RENEWAL_INTERVAL
  MAPPING_DESCRIPTION = "codex"

type PortMappingStrategy* = enum
  Any
  Upnp
  Pmp
  None

type MappingPort* = ref object of RootObj
  value*: Port

proc `$`(p: MappingPort): string =
  $(p.value)

type TcpPort* = ref object of MappingPort
type UdpPort* = ref object of MappingPort

proc newTcpMappingPort*(value: Port): TcpPort =
  TcpPort(value: value)

proc newUdpMappingPort*(value: Port): UdpPort =
  UdpPort(value: value)

type PortMapping* = tuple[internalPort: MappingPort, externalPort: Option[MappingPort]]
type RenewelThreadArgs =
  tuple[strategy: PortMappingStrategy, portMapping: seq[PortMapping]]

var
  upnp {.threadvar.}: Miniupnp
  npmp {.threadvar.}: NatPmp
  mappings: seq[PortMapping]
  portMappingExiting: Atomic[bool]
  renewalThread: Thread[RenewelThreadArgs]

proc initUpnp(): bool =
  logScope:
    protocol = "upnp"

  if upnp != nil:
    warn "UPnP already initialized!"
    return true

  upnp = newMiniupnp()
  upnp.discoverDelay = UPNP_TIMEOUT

  if err =? upnp.discover().errorOption:
    warn "UPnP error discoverning Internet Gateway Devices", msg = err
    upnp = nil
    return false

  case upnp.selectIGD()
  of IGDNotFound:
    info "UPnP Internet Gateway Device not found. Giving up."
    upnp = nil
      # As UPnP is not supported on our network we won't be using it --> lets erase it.
  of IGDFound:
    info "UPnP Internet Gateway Device found."
  of IGDNotConnected:
    info "UPnP Internet Gateway Device found but it's not connected. Trying anyway."
  of NotAnIGD:
    info "Some device found, but it's not recognised as an Internet Gateway Device. Trying anyway."
  of IGDIpNotRoutable:
    info "UPnP Internet Gateway Device found and is connected, but with a reserved or non-routable IP. Trying anyway."

  return true

proc initNpmp(): bool =
  logScope:
    protocol = "npmp"

  if npmp != nil:
    warn "NAT-PMP already initialized!"
    return true

  npmp = newNatPmp()

  if err =? npmp.init().errorOption:
    warn "Error initialization of NAT-PMP", msg = err
    npmp = nil
    return false

  if err =? npmp.externalIPAddress().errorOption:
    warn "Fetching of external IP failed.", msg = err
    npmp = nil
    return false

  info "NAT-PMP initialized"
  return true

## Try to initilize all the port mapping protocols and returns
## the protocol that will be used.
proc initProtocols(strategy: PortMappingStrategy): PortMappingStrategy =
  if strategy == PortMappingStrategy.Any or strategy == PortMappingStrategy.Upnp:
    if initUpnp():
      return PortMappingStrategy.Upnp

  if strategy == PortMappingStrategy.Any or strategy == PortMappingStrategy.Pmp:
    if initNpmp():
      return PortMappingStrategy.Pmp

  return PortMappingStrategy.None

proc upnpPortMapping(
    internalPort: MappingPort, externalPort: MappingPort
): ?!MappingPort {.gcsafe.} =
  let protocol = if (internalPort is TcpPort): UPNPProtocol.TCP else: UPNPProtocol.UDP

  logScope:
    protocol = "upnp"
    externalPort = externalPort.value
    internalPort = internalPort.value
    protocol = protocol

  let pmres = upnp.addPortMapping(
    externalPort = $(externalPort.value),
    protocol = protocol,
    internalHost = upnp.lanAddr,
    internalPort = $(internalPort.value),
    desc = MAPPING_DESCRIPTION,
    leaseDuration = 0,
  )

  if pmres.isErr:
    error "UPnP port mapping", msg = pmres.error
    return failure($pmres.error)

  # let's check it
  let cres = upnp.getSpecificPortMapping(
    externalPort = $(externalPort.value), protocol = protocol
  )
  if cres.isErr:
    warn "UPnP port mapping check failed. Assuming the check itself is broken and the port mapping was done.",
      msg = cres.error
  info "UPnP added port mapping"

  return success(externalPort)

proc npmpPortMapping(
    internalPort: MappingPort, externalPort: MappingPort
): ?!MappingPort {.gcsafe.} =
  let protocol =
    if (internalPort is TcpPort): NatPmpProtocol.TCP else: NatPmpProtocol.UDP

  logScope:
    protocol = "npmp"
    externalPort = externalPort.value
    internalPort = internalPort.value
    protocol = protocol

  let extPortRes = npmp.addPortMapping(
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

proc doPortMapping(port: MappingPort): ?!MappingPort {.gcsafe.} =
  if upnp != nil:
    return upnpPortMapping(port, port)

  if npmp != nil:
    return npmpPortMapping(port, port)

  return failure("No active startegy")

proc doPortMapping(
    internalPort: MappingPort, externalPort: MappingPort
): ?!MappingPort {.gcsafe.} =
  if upnp != nil:
    return upnpPortMapping(internalPort, externalPort)

  if npmp != nil:
    return npmpPortMapping(internalPort, externalPort)

  return failure("No active startegy")

proc renewPortMapping(args: RenewelThreadArgs) {.thread, raises: [ValueError].} =
  ignoreSignalsInThread()
  let
    (strategy, portMappings) = args
    interval = initDuration(seconds = RENEWAL_INTERVAL)
    sleepDuration = 1_000 # in ms, also the maximum delay after pressing Ctrl-C

  var lastUpdate = now()

  # We can't use copies of Miniupnp and Pmp objects in this thread, because they share
  # C pointers with other instances that have already been garbage collected, so
  # we use threadvars instead and initialise them again with initProtocols(),
  # even though we don't need the external IP's value.

  if initProtocols(strategy) == PortMappingStrategy.None:
    error "Could not initiate protocols in renewal thread"
    return

  while portMappingExiting.load() == false:
    if now() >= (lastUpdate + interval):
      for mapping in portMappings:
        if externalPort =? mapping.externalPort:
          without renewedExternalPort =?
            doPortMapping(mapping.internalPort, externalPort), err:
            error "Error while renewal of port mapping", msg = err.msg

          if renewedExternalPort.value != externalPort.value:
            error "The renewed external port is not the same as the originally mapped"

      lastUpdate = now()

    sleep(sleepDuration)

proc startRenewalThread(strategy: PortMappingStrategy) =
  try:
    renewalThread = Thread[RenewelThreadArgs]()
    renewalThread.createThread(renewPortMapping, (strategy, mappings))
  except CatchableError as exc:
    warn "Failed to create NAT port mapping renewal thread", exc = exc.msg

## Gets external IP provided by the port mapping protocols
## Port mapping needs to be succesfully started first using `startPortMapping()`
proc getExternalIP*(): ?IpAddress =
  if upnp == nil and npmp == nil:
    warn "No available port-mapping protocol"
    return IpAddress.none

  if upnp != nil:
    let ires = upnp.externalIPAddress
    if ires.isOk():
      info "Got externa IP address", ip = ires.value
      try:
        return parseIpAddress(ires.value).some
      except ValueError as e:
        error "Failed to parse IP address", err = e.msg
    else:
      debug "Getting external IP address using UPnP failed",
        msg = ires.error, protocol = "upnp"

  if npmp != nil:
    let nires = npmp.externalIPAddress()
    if nires.isErr:
      debug "Getting external IP address using NAT-PMP failed", msg = nires.error
    else:
      try:
        info "Got externa IP address", ip = $(nires.value), protocol = "npmp"
        return parseIpAddress($(nires.value)).some
      except ValueError as e:
        error "Failed to parse IP address", err = e.msg

  return IpAddress.none

proc startPortMapping*(
    strategy: var PortMappingStrategy, internalPorts: seq[MappingPort]
): ?!seq[PortMapping] =
  if strategy == PortMappingStrategy.None:
    return failure("No port mapping strategy requested")

  if internalPorts.len == 0:
    return failure("No internal ports to be mapped were supplied")

  strategy = initProtocols(strategy)
  if strategy == PortMappingStrategy.None:
    return failure("No available port mapping protocols on the network")

  if mappings.len > 0:
    return failure("Port mapping was already started! Stop first before re-starting.")

  mappings = newSeqOfCap[PortMapping](internalPorts.len)

  for port in internalPorts:
    without mappedPort =? doPortMapping(port), err:
      warn "Failed to map port", port = port, msg = err.msg
      mappings.add((internalPort: port, externalPort: MappingPort.none))

    mappings.add((internalPort: port, externalPort: mappedPort.some))

  startRenewalThread(strategy)

  return success(mappings)

proc stopPortMapping*() =
  if upnp == nil or npmp == nil:
    debug "Port mapping is not running, nothing to stop"
    return

  info "Stopping port mapping renewal threads"
  try:
    portMappingExiting.store(true)
    renewalThread.joinThread()
  except CatchableError as exc:
    warn "Failed to stop port mapping renewal thread", exc = exc.msg

  for mapping in mappings:
    if mapping.externalPort.isNone:
      continue

    if upnp != nil:
      let protocol =
        if (mapping.internalPort is TcpPort): UPNPProtocol.TCP else: UPNPProtocol.UDP

      if err =?
          upnp.deletePortMapping(
            externalPort = $((!mapping.externalPort).value), protocol = protocol
          ).errorOption:
        error "UPnP port mapping deletion error", msg = err
      else:
        debug "UPnP: deleted port mapping",
          externalPort = !mapping.externalPort,
          internalPort = mapping.internalPort,
          protocol = protocol

    if npmp != nil:
      let protocol =
        if (mapping.internalPort is TcpPort): NatPmpProtocol.TCP else: NatPmpProtocol.UDP

      if err =?
          npmp.deletePortMapping(
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

  mappings = @[]
