import std/sequtils

import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/libp2p
import pkg/libp2p/protocols/connectivity/autonat/client
import pkg/libp2p/protocols/connectivity/autonat/service

import ../rng as random
import ./port_mapping
import ./utils

const AutonatCheckInterval = Opt.some(chronos.seconds(30))

logScope:
  topics = "codex nat reachabilitymanager"

type
  ReachabilityManager* = ref object of RootObj
    started = false
    portMapping: PortMapping
    networkReachability*: NetworkReachability
    getAnnounceRecords*: ?GetRecords
    getDiscoveryRecords*: ?GetRecords
    updateAnnounceRecords*: ?UpdateRecords
    updateDiscoveryRecords*: ?UpdateRecords

  GetRecords* = proc(): ?seq[MultiAddress] {.raises: [].}
  UpdateRecords* = proc(records: seq[MultiAddress]) {.raises: [].}

proc new*(
    T: typedesc[ReachabilityManager], portMappingStrategy: PortMappingStrategy
): T =
  return T(portMapping: PortMapping.new(portMappingStrategy))

proc startPortMapping(
    self: ReachabilityManager
): Future[bool] {.async: (raises: [CancelledError]).} =
  # This check guarantees us that the callbacks are set
  # and hence we can use ! (Option.get) without fear.
  if not self.started:
    warn "ReachabilityManager is not started, yet we are trying to map ports already!"
    return false

  try:
    {.gcsafe.}:
      let announceRecords = (!self.getAnnounceRecords)()
      let discoveryRecords = (!self.getDiscoveryRecords)()

    var records: seq[MultiAddress] = @[]

    if announceRecords.isSome:
      records.add(!announceRecords)
    if discoveryRecords.isSome:
      records.add(!discoveryRecords)

    let portsToBeMapped = records.mapIt(getAddressAndPort(it)).mapIt(it.port)

    without mappedPorts =? (await self.portMapping.start(portsToBeMapped)), err:
      warn "Could not start port mapping", msg = err.msg
      return false

    if mappedPorts.any(
      proc(x: PortMappingEntry): bool =
        isNone(x.externalPort)
    ):
      warn "Some ports were not mapped - not using port mapping then"
      return false

    info "Succesfully exposed ports", ports = portsToBeMapped

    if announceRecords.isSome:
      let announceMappedRecords = zip(
          !announceRecords, mappedPorts[0 .. (!announceRecords).len - 1]
        )
        .mapIt(getMultiAddr(getAddressAndPort(it[0]).ip, !it[1].externalPort))
      {.gcsafe.}:
        (!self.updateAnnounceRecords)(announceMappedRecords)

    if discoveryRecords.isSome:
      let discoveryMappedRecords = zip(
          !discoveryRecords,
          mappedPorts[(mappedPorts.len - (!discoveryRecords).len) .. ^1],
        )
        .mapIt(getMultiAddr(getAddressAndPort(it[0]).ip, !it[1].externalPort))
      {.gcsafe.}:
        (!self.updateDiscoveryRecords)(discoveryMappedRecords)

    return true
  except ValueError as exc:
    error "Error while starting port mapping", msg = exc.msg
    return false

proc getReachabilityHandler(manager: ReachabilityManager): StatusAndConfidenceHandler =
  let statusAndConfidenceHandler = proc(
      networkReachability: NetworkReachability, confidenceOpt: Opt[float]
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    if not manager.started:
      warn "ReachabilityManager was not started, but we are already getting reachability updates! Ignoring..."
      return

    without confidence =? confidenceOpt:
      debug "Node reachability reported without confidence"
      return

    if manager.networkReachability == networkReachability:
      debug "Node reachability reported without change",
        networkReachability = networkReachability
      return

    info "Node reachability status changed",
      networkReachability = networkReachability, confidence = confidenceOpt

    manager.networkReachability = networkReachability

    if networkReachability == NetworkReachability.NotReachable:
      # Lets first start to expose port using port mapping protocols like NAT-PMP or UPnP
      if manager.portMapping.isAvailable():
        debug "Port mapping available on the network"

        if await manager.startPortMapping():
          return # We exposed ports so we should be good!

      info "No more options to become reachable"

  return statusAndConfidenceHandler

proc start*(
    self: ReachabilityManager, switch: Switch, bootNodes: seq[SignedPeerRecord]
): Future[void] {.async: (raises: [CancelledError]).} =
  doAssert self.getAnnounceRecords.isSome, "getAnnounceRecords is not set"
  doAssert self.getDiscoveryRecords.isSome, "getDiscoveryRecords is not set"
  doAssert self.updateAnnounceRecords.isSome, "updateAnnounceRecords is not set"
  doAssert self.updateDiscoveryRecords.isSome, "updateDiscoveryRecords is not set"
  self.started = true

  ## Until more robust way of NAT-traversal helper peers discovery is implemented
  ## we will start with simple populating the libp2p peerstore with bootstrap nodes
  ## https://github.com/codex-storage/nim-codex/issues/1320

  for peer in bootNodes:
    try:
      await switch.connect(peer.data.peerId, peer.data.addresses.mapIt(it.address))
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      info "Failed to dial bootstrap nodes", err = exc.msg

proc stop*(
    self: ReachabilityManager
): Future[void] {.async: (raises: [CancelledError]).} =
  await self.portMapping.stop()
  self.started = false

proc getAutonatService*(self: ReachabilityManager): Service =
  ## AutonatService request other peers to dial us back
  ## flagging us as Reachable or NotReachable.
  ## We use minimum confidence 0.1 (confidence is calculated as numOfReplies/maxQueueSize) as
  ## that will give an answer already for response from one peer.
  ## As we use bootnodes for this in initial setup, it is possible we might
  ## get only one peer to ask about our reachability and it is crucial to get at least some reply.
  ## This should be changed once proactive NAT-traversal helper peers discovery is implemented.

  let autonatService = AutonatService.new(
    autonatClient = AutonatClient.new(),
    rng = random.Rng.instance(),
    scheduleInterval = AutonatCheckInterval,
    askNewConnectedPeers = true,
    numPeersToAsk = 5,
    maxQueueSize = 10,
    minConfidence = 0.1,
  )

  autonatService.statusAndConfidenceHandler(self.getReachabilityHandler())

  return Service(autonatService)
