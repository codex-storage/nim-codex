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

const AutonatCheckInterval = Opt.some(chronos.seconds(30))

logScope:
  topics = "codex nat reachabilitymanager"

type
  ReachabilityManager* = ref object of RootObj
    networkReachability*: NetworkReachability
    portMappingStrategy: PortMappingStrategy
    getAnnounceRecords*: ?GetRecords
    getDiscoveryRecords*: ?GetRecords
    updateAnnounceRecords*: ?UpdateRecords
    updateDiscoveryRecords*: ?UpdateRecords
    started = false

  GetRecords* = proc(): seq[MultiAddress] {.raises: [].}
  UpdateRecords* = proc(records: seq[MultiAddress]) {.raises: [].}

proc new*(
    T: typedesc[ReachabilityManager], portMappingStrategy: PortMappingStrategy
): T =
  return T(portMappingStrategy: portMappingStrategy)

proc getReachabilityHandler(manager: ReachabilityManager): StatusAndConfidenceHandler =
  let statusAndConfidenceHandler = proc(
      networkReachability: NetworkReachability, confidenceOpt: Opt[float]
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    if not started:
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

    if networkReachability == NetworkReachability.Unreachable:
      # Lets first start to expose port using port mapping protocols like NAT-PMP or UPnP
      if manager.startPortMapping():
        return # We exposed ports so we should be good!

      info "No more options to become reachable"

  return statusAndConfidenceHandler

proc startPortMapping(self: ReachabilityManager): bool =
  try:
    let announceRecords = self.getAnnounceRecords()
    let discoveryRecords = self.getDiscoveryRecords()
    let portsToBeMapped =
      (announceRecords & discoveryRecords).mapIt(getAddressAndPort(it)).mapIt(it.port)

    without mappedPorts =? startPortMapping(
      manager.portMappingStrategy, portsToBeMapped
    ), err:
      warn "Could not start port mapping", msg = err
      return false

    if mappedPorts.any(
      proc(x: ?MappingPort): bool =
        isNone(x)
    ):
      warn "Some ports were not mapped - not using port mapping then"
      return false

    info "Started port mapping"

    let announceMappedRecords = zip(
        announceRecords, mappedPorts[0 .. announceRecords.len - 1]
      )
      .mapIt(getMultiAddr(getAddressAndPort(it[0]).ip, it[1].value))
    self.updateAnnounceRecords(announceMappedRecords)

    let discoveryMappedRecords = zip(
        discoveryRecords, mappedPorts[announceRecords.len, ^1]
      )
      .mapIt(getMultiAddr(getAddressAndPort(it[0]).ip, it[1].value))
    self.updateDiscoveryRecords(discoveryMappedRecords)

    return true
  except ValueError as exc:
    error "Error while starting port mapping", msg = exc.msg
    return false

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

proc stop*(): Future[void] {.async: (raises: [CancelledError]).} =
  stopPortMapping()
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
