## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/chronos
import ../../asyncyeah
import pkg/chronicles
import pkg/libp2p
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ../protobuf/presence

import ../network
import ../peers

import ../../utils
import ../../discovery
import ../../stores/blockstore

import ./pendingblocks

logScope:
  topics = "codex discoveryengine"

declareGauge(codexInflightDiscovery, "inflight discovery requests")

const
  DefaultConcurrentDiscRequests = 10
  DefaultConcurrentAdvertRequests = 10
  DefaultDiscoveryTimeout = 1.minutes
  DefaultMinPeersPerBlock = 3
  DefaultDiscoveryLoopSleep = 3.seconds
  DefaultAdvertiseLoopSleep = 30.minutes

type
  DiscoveryEngine* = ref object of RootObj
    localStore*: BlockStore                                      # Local block store for this instance
    peers*: PeerCtxStore                                         # Peer context store
    network*: BlockExcNetwork                                    # Network interface
    discovery*: Discovery                                        # Discovery interface
    pendingBlocks*: PendingBlocksManager                         # Blocks we're awaiting to be resolved
    discEngineRunning*: bool                                     # Indicates if discovery is running
    concurrentAdvReqs: int                                       # Concurrent advertise requests
    concurrentDiscReqs: int                                      # Concurrent discovery requests
    advertiseLoop*: Future[void]                                 # Advertise loop task handle
    advertiseQueue*: AsyncQueue[Cid]                             # Advertise queue
    advertiseTasks*: seq[Future[void]]                           # Advertise tasks
    discoveryLoop*: Future[void]                                 # Discovery loop task handle
    heartbeatLoop*: Future[void]
    discoveryQueue*: AsyncQueue[Cid]                             # Discovery queue
    discoveryTasks*: seq[Future[void]]                           # Discovery tasks
    minPeersPerBlock*: int                                       # Max number of peers with block
    discoveryLoopSleep: Duration                                 # Discovery loop sleep
    advertiseLoopSleep: Duration                                 # Advertise loop sleep
    inFlightDiscReqs*: Table[Cid, Future[seq[SignedPeerRecord]]] # Inflight discovery requests
    inFlightAdvReqs*: Table[Cid, Future[void]]                   # Inflight advertise requests
    advertiseType*: BlockType                                    # Advertice blocks, manifests or both

proc discoveryQueueLoop(b: DiscoveryEngine) {.asyncyeah.} =
  while b.discEngineRunning:
    for cid in toSeq(b.pendingBlocks.wantList):
      try:
        await b.discoveryQueue.put(cid)
      except CatchableError as exc:
        trace "Exception in discovery loop", exc = exc.msg

    logScope:
      sleep = b.discoveryLoopSleep
      wanted = b.pendingBlocks.len

    trace "About to sleep discovery loop"
    await sleepAsync(b.discoveryLoopSleep)

proc heartbeatLoop(b: DiscoveryEngine) {.asyncyeah.} =
  while b.discEngineRunning:
    await sleepAsync(1.seconds)
    await sleepAsync(1.seconds)
    await sleepAsync(1.seconds)
    await sleepAsync(1.seconds)
    await sleepAsync(1.seconds)
    if globalBaselineYeahStack.len == 0:
      for entry in globalYeahStack:
        globalBaselineYeahStack.add(entry)

proc advertiseQueueLoop*(b: DiscoveryEngine) {.asyncyeah.} =
  while b.discEngineRunning:
    if cids =? await b.localStore.listBlocks(blockType = b.advertiseType):
      for c in cids:
        if cid =? await c:
          await b.advertiseQueue.put(cid)
          await sleepAsync(50.millis)

    trace "About to sleep advertise loop", sleep = b.advertiseLoopSleep
    await sleepAsync(b.advertiseLoopSleep)

  trace "Exiting advertise task loop"

proc advertiseTaskLoop(b: DiscoveryEngine) {.asyncyeah.} =
  ## Run advertise tasks
  ##

  while b.discEngineRunning:
    try:
      let
        cid = await b.advertiseQueue.get()

      if cid in b.inFlightAdvReqs:
        trace "Advertise request already in progress", cid
        continue

      try:
        let
          request = b.discovery.provide(cid)

        b.inFlightAdvReqs[cid] = request
        codexInflightDiscovery.set(b.inFlightAdvReqs.len.int64)
        trace "Advertising block", cid, inflight = b.inFlightAdvReqs.len
        await request

      finally:
        b.inFlightAdvReqs.del(cid)
        codexInflightDiscovery.set(b.inFlightAdvReqs.len.int64)
        trace "Advertised block", cid, inflight = b.inFlightAdvReqs.len
    except CatchableError as exc:
      trace "Exception in advertise task runner", exc = exc.msg

  trace "Exiting advertise task runner"

proc discoveryTaskLoop(b: DiscoveryEngine) {.asyncyeah.} =
  ## Run discovery tasks
  ##

  while b.discEngineRunning:
    try:
      let
        cid = await b.discoveryQueue.get()

      if cid in b.inFlightDiscReqs:
        trace "Discovery request already in progress", cid
        continue

      let
        haves = b.peers.peersHave(cid)

      trace "Current number of peers for block", cid, count = haves.len
      if haves.len < b.minPeersPerBlock:
        trace "Discovering block", cid
        try:
          let
            request = b.discovery
              .find(cid)
              .wait(DefaultDiscoveryTimeout)

          b.inFlightDiscReqs[cid] = request
          codexInflightDiscovery.set(b.inFlightAdvReqs.len.int64)
          let
            peers = await request

          trace "Discovered peers", peers = peers.len
          let
            dialed = await allFinished(
              peers.mapIt( b.network.dialPeer(it.data) ))

          for i, f in dialed:
            if f.failed:
              await b.discovery.removeProvider(peers[i].data.peerId)

        finally:
          b.inFlightDiscReqs.del(cid)
          codexInflightDiscovery.set(b.inFlightAdvReqs.len.int64)
    except CatchableError as exc:
      trace "Exception in discovery task runner", exc = exc.msg

  trace "Exiting discovery task runner"

proc queueFindBlocksReq*(b: DiscoveryEngine, cids: seq[Cid]) {.inline.} =
  for cid in cids:
    if cid notin b.discoveryQueue:
      try:
        trace "Queueing find block", cid, queue = b.discoveryQueue.len
        b.discoveryQueue.putNoWait(cid)
      except CatchableError as exc:
        trace "Exception queueing discovery request", exc = exc.msg

proc queueProvideBlocksReq*(b: DiscoveryEngine, cids: seq[Cid]) {.inline.} =
  for cid in cids:
    if cid notin b.advertiseQueue:
      try:
        trace "Queueing provide block", cid, queue = b.discoveryQueue.len
        b.advertiseQueue.putNoWait(cid)
      except CatchableError as exc:
        trace "Exception queueing discovery request", exc = exc.msg

proc start*(b: DiscoveryEngine) {.asyncyeah.} =
  ## Start the discengine task
  ##

  trace "Discovery engine start"

  if b.discEngineRunning:
    warn "Starting discovery engine twice"
    return

  b.discEngineRunning = true
  for i in 0..<b.concurrentAdvReqs:
    b.advertiseTasks.add(advertiseTaskLoop(b))

  for i in 0..<b.concurrentDiscReqs:
    b.discoveryTasks.add(discoveryTaskLoop(b))

  b.advertiseLoop = advertiseQueueLoop(b)
  b.discoveryLoop = discoveryQueueLoop(b)
  b.heartbeatLoop = heartbeatLoop(b)

proc stop*(b: DiscoveryEngine) {.asyncyeah.} =
  ## Stop the discovery engine
  ##

  trace "Discovery engine stop"
  if not b.discEngineRunning:
    warn "Stopping discovery engine without starting it"
    return

  b.discEngineRunning = false
  for task in b.advertiseTasks:
    if not task.finished:
      trace "Awaiting advertise task to stop"
      await task.cancelAndWait()
      trace "Advertise task stopped"

  for task in b.discoveryTasks:
    if not task.finished:
      trace "Awaiting discovery task to stop"
      await task.cancelAndWait()
      trace "Discovery task stopped"

  if not b.advertiseLoop.isNil and not b.advertiseLoop.finished:
    trace "Awaiting advertise loop to stop"
    await b.advertiseLoop.cancelAndWait()
    trace "Advertise loop stopped"

  if not b.discoveryLoop.isNil and not b.discoveryLoop.finished:
    trace "Awaiting discovery loop to stop"
    await b.discoveryLoop.cancelAndWait()
    trace "Discovery loop stopped"

  if not b.heartbeatLoop.isNil and not b.heartbeatLoop.finished:
    await b.heartbeatLoop.cancelAndWait()

  trace "Discovery engine stopped"

proc new*(
    T: type DiscoveryEngine,
    localStore: BlockStore,
    peers: PeerCtxStore,
    network: BlockExcNetwork,
    discovery: Discovery,
    pendingBlocks: PendingBlocksManager,
    concurrentAdvReqs = DefaultConcurrentAdvertRequests,
    concurrentDiscReqs = DefaultConcurrentDiscRequests,
    discoveryLoopSleep = DefaultDiscoveryLoopSleep,
    advertiseLoopSleep = DefaultAdvertiseLoopSleep,
    minPeersPerBlock = DefaultMinPeersPerBlock,
    advertiseType = BlockType.Both
): DiscoveryEngine =
  ## Create a discovery engine instance for advertising services
  ##
  DiscoveryEngine(
    localStore: localStore,
    peers: peers,
    network: network,
    discovery: discovery,
    pendingBlocks: pendingBlocks,
    concurrentAdvReqs: concurrentAdvReqs,
    concurrentDiscReqs: concurrentDiscReqs,
    advertiseQueue: newAsyncQueue[Cid](concurrentAdvReqs),
    discoveryQueue: newAsyncQueue[Cid](concurrentDiscReqs),
    inFlightDiscReqs: initTable[Cid, Future[seq[SignedPeerRecord]]](),
    inFlightAdvReqs: initTable[Cid, Future[void]](),
    discoveryLoopSleep: discoveryLoopSleep,
    advertiseLoopSleep: advertiseLoopSleep,
    minPeersPerBlock: minPeersPerBlock,
    advertiseType: advertiseType)
