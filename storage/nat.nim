# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[options, net, os, sequtils]
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
  closed: bool

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

method hasLiveMapping*(m: NatPortMapper, id: cint): bool {.base, gcsafe.} =
  hasMapping(id)

proc resetMappings(m: NatPortMapper) =
  if m.tcpMappingId.isSome:
    m.destroyMappingFor(m.tcpMappingId.get)
    m.tcpMappingId = none(cint)

  if m.udpMappingId.isSome:
    m.destroyMappingFor(m.udpMappingId.get)
    m.udpMappingId = none(cint)

  m.activeMappingProtocol = none(MappingProtocol)
  m.activeTcpPort = none(Port)
  m.activeUdpPort = none(Port)

method mapNatPorts*(
    m: NatPortMapper
): Future[Option[(Port, Port, MappingProtocol)]] {.
    async: (raises: [CancelledError]), base, gcsafe
.} =
  if m.closed or m.natConfig.hasExtIp:
    return none((Port, Port, MappingProtocol))

  # If both mappings are still active, return the stored ports without recreating.
  if m.tcpMappingId.isSome and m.hasLiveMapping(m.tcpMappingId.get) and
      m.udpMappingId.isSome and m.hasLiveMapping(m.udpMappingId.get):
    return some((m.activeTcpPort.get, m.activeUdpPort.get, m.activeMappingProtocol.get))

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
  if tcpRes.isErr:
    warn "TCP port mapping failed", msg = tcpRes.error
    return none((Port, Port, MappingProtocol))

  let udpRes = await m.createMappingFor(UDP, m.discoveryPort.uint16)
  if udpRes.isErr:
    warn "UDP port mapping failed", msg = udpRes.error
    m.destroyMappingFor(tcpRes.value.id)
    return none((Port, Port, MappingProtocol))

  m.tcpMappingId = some(tcpRes.value.id)
  m.udpMappingId = some(udpRes.value.id)
  m.activeMappingProtocol = some(tcpRes.value.mapping.mappingProtocol)
  m.activeTcpPort = some(Port(tcpRes.value.mapping.externalPort))
  m.activeUdpPort = some(Port(udpRes.value.mapping.externalPort))

  some((m.activeTcpPort.get, m.activeUdpPort.get, m.activeMappingProtocol.get))

proc close*(m: NatPortMapper) =
  m.resetMappings()

  if m.plumInitialized:
    discard cleanup()
    m.plumInitialized = false

proc stop*(m: NatPortMapper) =
  ## Ensure that any future AutoNAT callback does not re-initialize libplum.
  m.closed = true
  m.close()

proc isPortMapped*(m: NatPortMapper, port: Port): bool =
  m.activeTcpPort.isSome and m.activeTcpPort.get == port

method hasMappingIds*(m: NatPortMapper): bool {.base, gcsafe.} =
  # Only checks that mappings were created, not that they are still live
  # (use hasMapping() for liveness check).
  m.tcpMappingId.isSome and m.udpMappingId.isSome

proc setupMappedAddrMapper*(switch: Switch, natMapper: NatPortMapper) =
  ## We define a custom mapper that adds the externally-mapped address to
  ## peerInfo.addrs when a port mapping is active, so AutoNAT tests that port.
  ## PCP/NAT-PMP may grant an external port different from the listen port.
  let mapper: AddressMapper = proc(
      addrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.gcsafe, async: (raises: [CancelledError]).} =
    result = addrs

    if natMapper.activeTcpPort.isNone:
      return result

    let mappedPort = natMapper.activeTcpPort.get
    for listenAddr in switch.peerInfo.listenAddrs:
      # Dialable IP (observed public, or the listen IP if already public)
      # used with the mapped port.
      let mappedAddr = switch.peerStore.guessDialableAddr(listenAddr).remapAddr(
          port = some(mappedPort)
        )
      if mappedAddr.isPublicMA():
        # Insert first so AutoNAT dials it before the listen-port candidate (the
        # server tests only the first dialable address).
        result.insert(mappedAddr, 0)

    return result.deduplicate()

  switch.peerInfo.addressMappers.add(mapper)

method handleNatStatus*(
    m: NatPortMapper,
    networkReachability: NetworkReachability,
    dialBackAddr: Opt[MultiAddress],
    discoveryPort: Port,
    discovery: Discovery,
    switch: Switch,
    autoRelayService: AutoRelayService,
) {.async: (raises: [CancelledError]), base, gcsafe.} =
  if m.closed:
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

      discovery.announceDirectAddrs(
        @[dialBackAddr.get], udpPort = m.activeUdpPort.get(discoveryPort)
      )
    else:
      warn "Empty dialback address in AutoNat when node is Reachable"
  of NotReachable:
    var hasPortMapping = false

    discovery.protocol.clientMode = true

    if not autoRelayService.isRunning and discovery.announceAddrs.len > 0:
      # Remove any announced addresses, they will be replaced.
      # If the relay is running, the addresses will be updated on reservation.
      discovery.announceDirectAddrs(@[], udpPort = discoveryPort)

    if dialBackAddr.isNone:
      warn "Got empty dialback address in AutoNat when node is NotReachable"

      if m.hasMappingIds():
        m.close()
    elif m.hasMappingIds():
      warn "Not Reachable with active port mapping. The port mapping will be deleted and relay will start."

      # The mapping was created the the node is still not reachable.
      # In that case, we delete the mapping and relay will start.
      m.close()
    else:
      debug "Node is not reachable trying port mapping now"

      let maybePorts = await m.mapNatPorts()

      if maybePorts.isSome:
        let (tcpPort, udpPort, protocol) = maybePorts.get()

        info "Port mapping created successfully", tcpPort, udpPort, protocol

        # The address mapper uses the mapped port to build the candidate address
        # for AutoNAT; the announce happens once AutoNAT confirms Reachable.

        hasPortMapping = true
      else:
        # In case of failure, close the port mapping in order to rerun discover
        # on the next iteration
        m.close()

    if not hasPortMapping and not autoRelayService.isRunning:
      debug "No port mapping found let's start autorelay"

      await autoRelayService.start(switch)
      debug "AutoRelayService started"

proc reachabilityStr*(autonat: Option[AutonatV2Service]): string =
  if autonat.isSome:
    $autonat.get.networkReachability
  else:
    "Unknown"

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
