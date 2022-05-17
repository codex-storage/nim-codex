## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/chronos
import pkg/chronicles
import pkg/libp2p

import ../protobuf/blockexc
import ../protobuf/presence

import ../network
import ../peers

import ../../utils
import ../../discovery
import ../../stores/blockstore

import ../pendingblocks

logScope:
  topics = "dagger discovery engine"

const
  DefaultConcurrentDiscRequests = 10
  DefaultConcurrentAdvertRequests = 10
  DefaultDiscoveryTimeout = 1.minutes
  DefaultMinPeersPerBlock = 3
  DefaultDiscoveryLoopSleep = 30.seconds
  DefaultAdvertiseLoopSleep = 30.seconds

type
  DiscoveryEngine* = ref object of RootObj
    localStore*: BlockStore                                      # Local block store for this instance
    peers*: PeerCtxStore                                         # Peer context store
    network*: BlockExcNetwork                                    # Network interface
    discovery*: Discovery                                        # Discovery interface
    pendingBlocks*: PendingBlocksManager                         # Blocks we're awaiting to be resolved
    discEngineRunning*: bool                                     # Indicates if discovery is running
    concurrentAdvReqs: int                                       # Concurrent advertise requests
    advertiseLoop*: Future[void]                                 # Advertise loop task handle
    advertiseQueue*: AsyncQueue[Cid]                             # Advertise queue
    advertiseTasks*: seq[Future[void]]                           # Advertise tasks
    concurrentDiscReqs: int                                      # Concurrent discovery requests
    discoveryLoop*: Future[void]                                 # Discovery loop task handle
    discoveryTasks*: seq[Future[void]]                           # Discovery tasks
    discoveryQueue*: AsyncQueue[Cid]                             # Discovery queue
    minPeersPerBlock*: int                                       # Max number of peers with block
    discoveryLoopSleep: Duration                                 # Discovery loop sleep
    advertiseLoopSleep: Duration                                 # Advertise loop sleep
    inFlightDiscReqs*: Table[Cid, Future[seq[SignedPeerRecord]]] # Inflight discovery requests
    inFlightAdvReqs*: Table[Cid, Future[void]]                   # Inflight advertise requests

proc discoveryQueueLoop(b: DiscoveryEngine) {.async.} =
  while b.discEngineRunning:
    for cid in toSeq(b.pendingBlocks.wantList):
      try:
        await b.discoveryQueue.put(cid)
      except CatchableError as exc:
        trace "Exception in discovery loop", exc = exc.msg

    trace "About to sleep, number of wanted blocks", wanted = b.pendingBlocks.len
    await sleepAsync(b.discoveryLoopSleep)

proc advertiseQueueLoop*(b: DiscoveryEngine) {.async.} =
  proc onBlock(cid: Cid) {.async.} =
    try:
      await b.advertiseQueue.put(cid)
    except CancelledError as exc:
      trace "Cancelling block listing"
      raise exc
    except CatchableError as exc:
      trace "Exception listing blocks", exc = exc.msg

  while b.discEngineRunning:
    await b.localStore.listBlocks(onBlock)
    await sleepAsync(b.advertiseLoopSleep)

  trace "Exiting advertise task loop"

proc advertiseTaskLoop(b: DiscoveryEngine) {.async.} =
  ## Run advertise tasks
  ##

  while b.discEngineRunning:
    try:
      let
        cid = await b.advertiseQueue.get()

      if cid in b.inFlightAdvReqs:
        trace "Advertise request already in progress", cid = $cid
        continue

      try:
        let request = b.discovery.provideBlock(cid)
        b.inFlightAdvReqs[cid] = request
        await request
      finally:
        b.inFlightAdvReqs.del(cid)
    except CatchableError as exc:
      trace "Exception in advertise task runner", exc = exc.msg

  trace "Exiting advertise task runner"

proc discoveryTaskLoop(b: DiscoveryEngine) {.async.} =
  ## Run discovery tasks
  ##

  while b.discEngineRunning:
    try:
      let
        cid = await b.discoveryQueue.get()

      if cid in b.inFlightDiscReqs:
        trace "Discovery request already in progress", cid = $cid
        continue

      let
        haves = b.peers.peersHave(cid)

      trace "Current number of peers for block", cid = $cid, count = haves.len
      if haves.len < b.minPeersPerBlock:
        trace "Issuing discovery request", cid = $cid
        try:
          let
            request = b.discovery
              .findBlockProviders(cid)
              .wait(DefaultDiscoveryTimeout)

          b.inFlightDiscReqs[cid] = request

          checkFutures (await request).mapIt( b.network.dialPeer(it.data) )
        finally:
          b.inFlightDiscReqs.del(cid)
    except CatchableError as exc:
      trace "Exception in discovery task runner", exc = exc.msg

  trace "Exiting discovery task runner"

proc queueFindBlocksReq*(b: DiscoveryEngine, cids: seq[Cid]) {.inline.} =
  proc queueReq() {.async.} =
    try:
      for cid in cids:
        if cid notin b.discoveryQueue:
          trace "Queueing find block request", cid = $cid
          await b.discoveryQueue.put(cid)
    except CatchableError as exc:
      trace "Exception queueing discovery request", exc = exc.msg

  asyncSpawn queueReq()

proc queueProvideBlocksReq*(b: DiscoveryEngine, cids: seq[Cid]) {.inline.} =
  proc queueReq() {.async.} =
    try:
      for cid in cids:
        if cid notin b.advertiseQueue:
          trace "Queueing provide block request", cid = $cid
          await b.advertiseQueue.put(cid)
    except CatchableError as exc:
      trace "Exception queueing discovery request", exc = exc.msg

  asyncSpawn queueReq()

proc start*(b: DiscoveryEngine) {.async.} =
  ## Start the discengine task
  ##

  trace "discovery engine start"

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

proc stop*(b: DiscoveryEngine) {.async.} =
  ## Stop the discovery engine
  ##

  trace "NetworkStore stop"
  if not b.discEngineRunning:
    warn "Stopping discovery engine without starting it"
    return

  b.discEngineRunning = false
  for t in b.advertiseTasks:
    if not t.finished:
      trace "Awaiting task to stop"
      await t.cancelAndWait()
      trace "Task stopped"

  for t in b.discoveryTasks:
    if not t.finished:
      trace "Awaiting task to stop"
      await t.cancelAndWait()
      trace "Task stopped"

  if not b.advertiseLoop.isNil and not b.advertiseLoop.finished:
    trace "Awaiting advertise loop to stop"
    await b.advertiseLoop.cancelAndWait()
    trace "Advertise loop stopped"

  if not b.discoveryLoop.isNil and not b.discoveryLoop.finished:
    trace "Awaiting discovery loop to stop"
    await b.discoveryLoop.cancelAndWait()
    trace "Discovery loop stopped"

  trace "NetworkStore stopped"

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
  minPeersPerBlock = DefaultMinPeersPerBlock,): DiscoveryEngine =
  T(
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
    minPeersPerBlock: minPeersPerBlock)
