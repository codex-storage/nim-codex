# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[options, net]
import results

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/libp2p/services/autorelayservice
import pkg/libp2p/protocols/connectivity/autonatv2/service

import ./utils
import ./utils/natutils
import ./utils/addrutils
import ./discovery

logScope:
  topics = "nat"

type NatConfig* = object
  case hasExtIp*: bool
  of true: extIp*: IpAddress
  of false: nat*: NatStrategy

type NatMapper* = ref object of RootObj
  natConfig*: NatConfig
  tcpPort*: Port
  discoveryPort*: Port
  discoverTimeout*: int
  mappingTimeout*: int
  recheckPeriod*: int
  tcpMappingId: Option[cint]
  udpMappingId: Option[cint]
  activeMappingProtocol*: Option[MappingProtocol]
  activeTcpPort: Option[Port]
  activeUdpPort: Option[Port]
  plumInitialized: bool

method mapNatPorts*(
    m: NatMapper
): Future[Option[(Port, Port, MappingProtocol)]] {.
    async: (raises: [CancelledError]), base, gcsafe
.} =
  if m.natConfig.hasExtIp:
    return none((Port, Port, MappingProtocol))

  # If both mappings are still active, return the stored ports without recreating.
  if m.tcpMappingId.isSome and hasMapping(m.tcpMappingId.get) and m.udpMappingId.isSome and
      hasMapping(m.udpMappingId.get):
    return some((m.activeTcpPort.get, m.activeUdpPort.get, m.activeMappingProtocol.get))

  if not m.plumInitialized:
    # 5s matches the old NatPortMappingTimeout used with miniupnpc/libnatpmp.
    let res = init(
      discoverTimeout = m.discoverTimeout,
      mappingTimeout = m.mappingTimeout,
      recheckPeriod = m.recheckPeriod,
    )
    if res.isErr:
      warn "Failed to initialize plum", msg = res.error
      return none((Port, Port, MappingProtocol))
    m.plumInitialized = true

  # If there is only one mapping, something went wrong somewhere
  # so we delete the mappings to recreate them.
  if m.tcpMappingId.isSome:
    destroyMapping(m.tcpMappingId.get)
    m.tcpMappingId = none(cint)

  if m.udpMappingId.isSome:
    destroyMapping(m.udpMappingId.get)
    m.udpMappingId = none(cint)

  m.activeMappingProtocol = none(MappingProtocol)
  m.activeTcpPort = none(Port)
  m.activeUdpPort = none(Port)

  let tcpRes = await createMapping(TCP, m.tcpPort.uint16)
  if tcpRes.isErr:
    warn "TCP port mapping failed", msg = tcpRes.error
    return none((Port, Port, MappingProtocol))

  let udpRes = await createMapping(UDP, m.discoveryPort.uint16)
  if udpRes.isErr:
    warn "UDP port mapping failed", msg = udpRes.error
    destroyMapping(tcpRes.value.id)
    return none((Port, Port, MappingProtocol))

  m.tcpMappingId = some(tcpRes.value.id)
  m.udpMappingId = some(udpRes.value.id)
  m.activeMappingProtocol = some(tcpRes.value.mapping.mappingProtocol)
  m.activeTcpPort = some(Port(tcpRes.value.mapping.externalPort))
  m.activeUdpPort = some(Port(udpRes.value.mapping.externalPort))

  some((m.activeTcpPort.get, m.activeUdpPort.get, m.activeMappingProtocol.get))

method handleNatStatus*(
    m: NatMapper,
    networkReachability: NetworkReachability,
    dialBackAddr: Opt[MultiAddress],
    discoveryPort: Port,
    discovery: Discovery,
    switch: Switch,
    autoRelayService: AutoRelayService,
) {.async: (raises: [CancelledError]), base, gcsafe.} =
  case networkReachability
  of Unknown:
    discard
  of Reachable:
    if dialBackAddr.isNone:
      warn "Got empty dialback address in AutoNat when node is Reachable"
      return

    if autoRelayService.isRunning:
      if not await autoRelayService.stop(switch):
        debug "AutoRelayService stop method returned false"
      else:
        debug "AutoRelayService stopped"

    discovery.updateRecords(@[dialBackAddr.get], udpPort = discoveryPort)
    discovery.protocol.clientMode = false
  of NotReachable:
    var hasPortMapping = false

    discovery.protocol.clientMode = true

    if dialBackAddr.isNone:
      warn "Got empty dialback address in AutoNat when node is NotReachable"
    else:
      debug "Node is not reachable trying port mapping now"

      # Here we should check first that a mapping exists.
      # If it does exist but Autonat still report as Not Reachable
      # we should fallback to relay.
      let maybePorts = await m.mapNatPorts()

      if maybePorts.isSome:
        let (tcpPort, udpPort, protocol) = maybePorts.get()

        info "Port mapping created successfully", tcpPort, udpPort, protocol

        let announceAddress = dialBackAddr.get.remapAddr(port = some(tcpPort))

        if autoRelayService.isRunning:
          # Here we stop the relay because the node *should* be reachable
          if not await autoRelayService.stop(switch):
            debug "AutoRelayService stop method returned false"
          else:
            debug "AutoRelayService stopped"

        # Note that we update the DHT records but we don't set the client mode
        # to false because we are not sure the node is reachable.
        # The client mode will be updated on the next iteration of autonat.
        # Trying to check manually that the node is reachable is not trivial,
        # this is exactly what Autonat does.
        discovery.updateRecords(@[announceAddress], udpPort = udpPort)
        hasPortMapping = true

    if not hasPortMapping and not autoRelayService.isRunning:
      debug "No port mapping found let's start autorelay"

      if not await autoRelayService.setup(switch):
        warn "Cannot start autorelay service"
      else:
        debug "AutoRelayService started"

proc close*(m: NatMapper) =
  if m.tcpMappingId.isSome:
    destroyMapping(m.tcpMappingId.get)
    m.tcpMappingId = none(cint)
  if m.udpMappingId.isSome:
    destroyMapping(m.udpMappingId.get)
    m.udpMappingId = none(cint)
  if m.plumInitialized:
    discard cleanup()
    m.plumInitialized = false

proc reachabilityStr*(autonat: Option[AutonatV2Service]): string =
  if autonat.isSome:
    $autonat.get.networkReachability
  else:
    "unknown"

proc portMappingStr*(natMapper: Option[NatMapper]): string =
  if natMapper.isNone or natMapper.get.activeMappingProtocol.isNone:
    return "none"
  case natMapper.get.activeMappingProtocol.get
  of MappingProtocol.UPnP: "upnp"
  of MappingProtocol.NatPmp: "pmp"
  of MappingProtocol.PCP: "pcp"
  of MappingProtocol.Direct: "direct"
  of MappingProtocol.Unknown: "none"

proc findReachableNodes*(bootstrapNodes: seq[SignedPeerRecord]): seq[SignedPeerRecord] =
  ## Returns the list of nodes known to be directly reachable.
  ## Currently returns bootstrap nodes. In the future, any network participant
  ## confirmed reachable by AutoNAT could be included.
  bootstrapNodes
