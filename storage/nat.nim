# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[options, net, os, sequtils, json]
import results

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/libp2p/services/autorelayservice
import pkg/libp2p/protocols/connectivity/autonatv2/service
import pkg/libp2p/protocols/connectivity/relay/relay as relayProtocol
import pkg/libp2p/protocols/connectivity/dcutr/client as dcutrClientModule
import pkg/libp2p/protocols/connectivity/dcutr/server as dcutrServerModule
import pkg/libp2p/wire

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

type PortMapping* = object
  tcpMappingId: cint
  udpMappingId: cint
  activeMappingProtocol*: MappingProtocol
  activeTcpPort*: Port
  activeUdpPort*: Port

type NatPortMapper* = ref object of RootObj
  natConfig*: NatConfig
  tcpPort*: Port
  discoveryPort*: Port
  discoverTimeout*: int
  mappingTimeout*: int
  recheckPeriod*: int
  portMapping*: Option[PortMapping]
  plumInitialized: bool
  stopped: bool

# libplum seams, extracted as methods so tests can override them without I/O.

method initPlum*(m: NatPortMapper): Result[void, string] {.base, gcsafe.} =
  let plumLogLevel =
    if getEnv("DEBUG") == "1": PlumLogLevel.Verbose else: PlumLogLevel.None
  init(
    logLevel = plumLogLevel,
    discoverTimeout = m.discoverTimeout.int32,
    mappingTimeout = m.mappingTimeout.int32,
    recheckPeriod = m.recheckPeriod.int32,
  )

method createMappingFor*(
    m: NatPortMapper, protocol: PlumProtocol, port: uint16
): Future[Result[MappingResult, string]] {.
    base, async: (raises: [CancelledError]), gcsafe
.} =
  await createMapping(protocol, port, port)

method destroyMappingFor*(m: NatPortMapper, id: cint) {.base, gcsafe.} =
  destroyMapping(id)

method hasLivePortMapping*(m: NatPortMapper): bool {.base, gcsafe.} =
  ## True only when a mapping was created AND both the TCP and UDP mappings are
  ## still live in the router.
  if m.portMapping.isNone:
    return false

  let pm = m.portMapping.get
  hasMapping(pm.tcpMappingId) and hasMapping(pm.udpMappingId)

proc resetMappings(m: NatPortMapper) =
  if m.portMapping.isSome:
    let pm = m.portMapping.get
    m.destroyMappingFor(pm.tcpMappingId)
    m.destroyMappingFor(pm.udpMappingId)
    m.portMapping = none(PortMapping)

method mapNatPorts*(
    m: NatPortMapper
): Future[Option[(Port, Port, MappingProtocol)]] {.
    async: (raises: [CancelledError]), base, gcsafe
.} =
  if m.stopped or m.natConfig.hasExtIp:
    return none((Port, Port, MappingProtocol))

  # If both mappings are still live, return the stored ports without recreating.
  if m.hasLivePortMapping():
    let pm = m.portMapping.get
    return some((pm.activeTcpPort, pm.activeUdpPort, pm.activeMappingProtocol))

  if not m.plumInitialized:
    let res = m.initPlum()
    if res.isErr:
      warn "Failed to initialize plum", msg = res.error
      return none((Port, Port, MappingProtocol))
    m.plumInitialized = true

  # If there is only one mapping, something went wrong somewhere
  # so we delete the mappings to recreate them.
  m.resetMappings()

  let tcpRes = await m.createMappingFor(TCP, m.tcpPort.uint16)

  if m.stopped:
    # Double check in case the node is stopping
    return none((Port, Port, MappingProtocol))

  if tcpRes.isErr:
    warn "TCP port mapping failed", msg = tcpRes.error
    return none((Port, Port, MappingProtocol))

  let udpRes = await m.createMappingFor(UDP, m.discoveryPort.uint16)

  if m.stopped:
    # Double check in case the node is stopping
    return none((Port, Port, MappingProtocol))

  if udpRes.isErr:
    warn "UDP port mapping failed", msg = udpRes.error
    m.destroyMappingFor(tcpRes.value.id)
    return none((Port, Port, MappingProtocol))

  m.portMapping = some(
    PortMapping(
      tcpMappingId: tcpRes.value.id,
      udpMappingId: udpRes.value.id,
      activeMappingProtocol: tcpRes.value.mapping.mappingProtocol,
      activeTcpPort: Port(tcpRes.value.mapping.externalPort),
      activeUdpPort: Port(udpRes.value.mapping.externalPort),
    )
  )

  let pm = m.portMapping.get
  some((pm.activeTcpPort, pm.activeUdpPort, pm.activeMappingProtocol))

proc close*(m: NatPortMapper) =
  m.resetMappings()

  if m.plumInitialized:
    discard cleanup()
    m.plumInitialized = false

proc start*(m: NatPortMapper) =
  m.stopped = false

proc stop*(m: NatPortMapper) =
  ## Ensure that any future AutoNAT callback does not re-initialize libplum.
  m.stopped = true
  m.close()

method handleNatStatus*(
    m: NatPortMapper,
    networkReachability: NetworkReachability,
    dialBackAddr: Opt[MultiAddress],
    discoveryPort: Port,
    discovery: Discovery,
    switch: Switch,
    autoRelayService: AutoRelayService,
) {.async: (raises: [CancelledError]), base, gcsafe.} =
  if m.stopped:
    return

  case networkReachability
  of Unknown:
    discard
  of Reachable:
    if dialBackAddr.isSome:
      if autoRelayService.isRunning:
        await autoRelayService.stop(switch)
        debug "AutoRelayService stopped"

      discovery.protocol.clientMode = false

      # Here we don't rely on the port mapping because we consider
      # that port mapped is the same as the discovery port.
      # This can be wrong for PCP but it is an accepted limitation
      discovery.announceDirectAddrs(@[dialBackAddr.get], udpPort = discoveryPort)
    else:
      warn "Empty dialback address in AutoNat when node is Reachable"
  of NotReachable:
    discovery.protocol.clientMode = true

    if not autoRelayService.isRunning and discovery.announceAddrs.len > 0:
      # Remove any announced addresses, they will be replaced.
      # If the relay is running, the addresses will be updated on reservation.
      discovery.announceDirectAddrs(@[], udpPort = discoveryPort)

    if m.hasLivePortMapping():
      # The mapping is still live but the node is not reachable: keep it and let
      # the relay take over. A dead mapping falls through to be recreated.
      debug "Not Reachable with live port mapping, keeping it and starting relay if not started"
    else:
      debug "Node is not reachable trying port mapping now"

      let maybePorts = await m.mapNatPorts()

      if m.stopped:
        # Double check in case the node is stopping
        return

      if maybePorts.isSome:
        let (tcpPort, udpPort, protocol) = maybePorts.get()

        info "Port mapping created successfully", tcpPort, udpPort, protocol

        # The announce happens once AutoNAT confirms Reachable.

        return
      else:
        # In case of failure, close the port mapping in order to rerun discover
        # on the next iteration
        m.close()

    if not autoRelayService.isRunning:
      debug "No port mapping found let's start autorelay"

      await autoRelayService.start(switch)
      debug "AutoRelayService started"

proc reachabilityStr*(autonat: Option[AutonatV2Service]): string =
  if autonat.isSome:
    $autonat.get.networkReachability
  else:
    "Unknown"

proc portMappingStr*(natMapper: Option[NatPortMapper]): string =
  if natMapper.isNone or natMapper.get.portMapping.isNone:
    return "none"
  case natMapper.get.portMapping.get.activeMappingProtocol
  of MappingProtocol.UPnP: "upnp"
  of MappingProtocol.NatPmp: "pmp"
  of MappingProtocol.PCP: "pcp"
  of MappingProtocol.Direct: "direct"
  of MappingProtocol.Unknown: "none"

proc peerConnections*(switch: Switch): JsonNode =
  result = newJArray()
  for peerId, muxers in switch.connManager.getConnections():
    let entry = newJObject()
    entry["peerId"] = newJString($peerId)
    entry["direct"] = newJBool(muxers.anyIt(not isRelayed(it.connection)))
    result.add(entry)

proc findAutonatServers*(bootstrapNodes: seq[SignedPeerRecord]): seq[SignedPeerRecord] =
  ## Returns the list of Autonat servers.
  ## The nodes are expected to be directly reachable.
  ## Currently returns bootstrap nodes. In the future, any network participant
  ## confirmed reachable by AutoNAT and running as AutonatServer could be included.
  bootstrapNodes

proc announceRelayReservation*(
    discovery: Discovery, addresses: seq[MultiAddress]
) {.gcsafe.} =
  ## Announce the publicly dialable circuit addresses from a relay reservation.
  ## A reservation response can also carry loopback/private addresses, which a
  ## remote peer can never dial, so they are dropped. If none are public, the
  ## previous announce is kept untouched.
  let publicAddrs = addresses.filterIt(it.hasPublicRelayTransport())
  if publicAddrs.len == 0:
    warn "Relay reservation has no publicly dialable address, keeping previous announce",
      addresses
    return
  info "Relay reservation updated", addresses = publicAddrs
  # relay addresses are for download traffic only, not DHT routing
  discovery.announceRelayAddrs(publicAddrs)

# Hole punching logic below is adapted from libp2p's HPService
# (libp2p/services/hpservice.nim). HPService cannot be used directly because it
# depends on AutoNAT v1 and starts the relay immediately on NotReachable,
# bypassing the UPnP step.

proc tryStartingDirectConn(
    switch: Switch, peerId: PeerId
): Future[bool] {.async: (raises: [CancelledError]).} =
  proc tryConnect(
      address: MultiAddress
  ): Future[bool] {.async: (raises: [DialFailedError, CancelledError]).} =
    debug "Trying to create direct connection", peerId, address
    await switch.connect(peerId, @[address], true, false)
    debug "Direct connection created."
    return true

  await sleepAsync(500.milliseconds) # wait for AddressBook to be populated
  for address in switch.peerStore[AddressBook][peerId]:
    try:
      let isRelayedAddr = address.contains(multiCodec("p2p-circuit"))
      if not isRelayedAddr.get(false) and address.isPublicMA():
        return await tryConnect(address)
    except CancelledError as exc:
      raise exc
    except CatchableError as err:
      debug "Failed to create direct connection.", description = err.msg
      continue
  return false

proc closeRelayConn(relayedConn: Connection) {.async: (raises: [CancelledError]).} =
  await sleepAsync(2000.milliseconds) # grace period before closing relayed connection
  await relayedConn.close()

proc holePunchIfRelayed*(
    switch: Switch, peerId: PeerId
) {.async: (raises: [CancelledError]).} =
  ## Attempts to establish a direct connection when a peer connected via relay.
  ## First tries a direct TCP connect (if the peer's address is known and public),
  ## then falls back to dcutr simultaneous-open hole punching.
  ## Closes the relay connection once a direct path is established.
  let connections =
    switch.connManager.getConnections().getOrDefault(peerId).mapIt(it.connection)
  if connections.anyIt(not isRelayed(it)):
    return
  let incomingRelays = connections.filterIt(it.transportDir == Direction.In)
  if incomingRelays.len == 0:
    return

  let relayedConn = incomingRelays[0]

  if await tryStartingDirectConn(switch, peerId):
    await closeRelayConn(relayedConn)
    return

  var natAddrs = switch.peerStore.getMostObservedProtosAndPorts()
  if natAddrs.len == 0:
    natAddrs = switch.peerInfo.listenAddrs.mapIt(switch.peerStore.guessDialableAddr(it))
  try:
    await DcutrClient.new().startSync(switch, peerId, natAddrs)
    await closeRelayConn(relayedConn)
  except DcutrError as err:
    debug "Hole punching failed during dcutr", description = err.msg

proc setupHolePunching*(switch: Switch): PeerEventHandler =
  try:
    switch.mount(Dcutr.new(switch))
  except LPError as err:
    error "Failed to mount Dcutr protocol", description = err.msg

  let handler = proc(
      peerId: PeerId, event: PeerEvent
  ) {.async: (raises: [CancelledError]).} =
    await holePunchIfRelayed(switch, peerId)
  switch.addPeerEventHandler(handler, PeerEventKind.Joined)
  handler
