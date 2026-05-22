# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[options, net, os]
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

type NatPortMapper* = ref object of RootObj
  natConfig*: NatConfig
  tcpPort*: Port
  discoveryPort*: Port
  discoverTimeout*: int
  mappingTimeout*: int
  recheckPeriod*: int
  tcpMappingId: Option[cint]
  udpMappingId: Option[cint]
  activeMappingProtocol*: Option[MappingProtocol]
  activeTcpPort*: Option[Port]
  activeUdpPort*: Option[Port]
  plumInitialized: bool

method mapNatPorts*(
    m: NatPortMapper
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
    let plumLogLevel =
      if getEnv("DEBUG") == "1": PLUM_LOG_LEVEL_VERBOSE
      else: PLUM_LOG_LEVEL_NONE
    let res = init(
      logLevel = plumLogLevel,
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

  let tcpRes = await createMapping(TCP, m.tcpPort.uint16, m.tcpPort.uint16)
  if tcpRes.isErr:
    warn "TCP port mapping failed", msg = tcpRes.error
    return none((Port, Port, MappingProtocol))

  let udpRes = await createMapping(UDP, m.discoveryPort.uint16, m.discoveryPort.uint16)
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

proc close*(m: NatPortMapper) =
  if m.tcpMappingId.isSome:
    destroyMapping(m.tcpMappingId.get)
    m.tcpMappingId = none(cint)

  if m.udpMappingId.isSome:
    destroyMapping(m.udpMappingId.get)
    m.udpMappingId = none(cint)

  m.activeMappingProtocol = none(MappingProtocol)
  m.activeTcpPort = none(Port)
  m.activeUdpPort = none(Port)

  if m.plumInitialized:
    discard cleanup()
    m.plumInitialized = false

proc isPortMapped*(m: NatPortMapper, port: Port): bool =
  m.activeTcpPort.isSome and m.activeTcpPort.get == port

method handleNatStatus*(
    m: NatPortMapper,
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
    elif m.tcpMappingId.isSome and m.udpMappingId.isSome:
      warn "Not Reachable with active port mapping. The port mapping will be deleted and relay will start."

      # The mapping was created the the node is still not reachable.
      # In that case, we delete the mapping and relay will start.
      # We will keep retrying on the next iteration
      m.close()

      # We remove the announced records.
      # Eventually, it will we updated by the relay when it started
      discovery.updateRecords(@[], udpPort = discoveryPort)
    else:
      debug "Node is not reachable trying port mapping now"

      let maybePorts = await m.mapNatPorts()

      if maybePorts.isSome:
        let (tcpPort, udpPort, protocol) = maybePorts.get()

        info "Port mapping created successfully", tcpPort, udpPort, protocol

        let announceAddress = dialBackAddr.get.remapAddr(port = some(tcpPort))

        if autoRelayService.isRunning:
          # Here we stop the relay because the node *should* be reachable
          if not await autoRelayService.stop(switch):
            debug "AutoRelayService returned an issue when trying to stop"
          else:
            debug "AutoRelayService stopped"

        # Note that we update the DHT records but we don't set the client mode
        # to false because we are not sure the node is reachable.
        # The client mode will be updated on the next iteration of autonat.
        # Trying to check manually that the node is reachable is not trivial,
        # this is exactly what Autonat is for.
        discovery.updateRecords(@[announceAddress], udpPort = udpPort)
        hasPortMapping = true
      else:
        # In case of failure, close the port mapping in order to rerun discover
        # on the next iteration
        m.close()

    if not hasPortMapping and not autoRelayService.isRunning:
      debug "No port mapping found let's start autorelay"

      if not await autoRelayService.setup(switch):
        warn "Unable to start autorelay service"
      else:
        debug "AutoRelayService started"

proc reachabilityStr*(autonat: Option[AutonatV2Service]): string =
  if autonat.isSome:
    $autonat.get.networkReachability
  else:
    "unknown"

proc portMappingStr*(natMapper: Option[NatPortMapper]): string =
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
