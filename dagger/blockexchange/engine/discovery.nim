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
import ../pendingblocks

import ../../utils
import ../../discovery
import ../../stores

logScope:
  topics = "dagger discovery engine"

const
  DefaultConcurrentDiscRequests = 10
  DefaultConcurrentAdvertRequests = 10
  DefaultDiscoveryTimeout = 1.minutes
  DefaultMaxQueriedBlocksCache = 1000
  DefaultMinPeersPerBlock = 3

type
  DiscoveryEngine = ref object of RootObj
    localStore*: BlockStore               # Local store for this instance
    discEngineRunning*: bool              # Indicates if discovery is running
    pendingBlocks*: PendingBlocksManager  # blocks we're awaiting to be resolved
    network*: BlockExcNetwork             # Network interface
    discovery*: Discovery                 # Discovery interface
    concurrentAdvReqs: int                # Concurrent advertise requests
    advertiseLoop*: Future[void]          # Advertise loop task handle
    advertiseQueue*: AsyncQueue[Cid]      # Advertise queue
    advertiseTasks*: seq[Future[void]]    # Advertise tasks
    concurrentDiscReqs: int               # Concurrent discovery requests
    discoveryLoop*: Future[void]          # Discovery loop task handle
    discoveryTasks*: seq[Future[void]]    # Discovery tasks
    discoveryQueue*: AsyncQueue[Cid]      # Discovery queue
    minPeersPerBlock*: int                # Max number of peers with block

proc discoveryLoopRunner(b: DiscoveryEngine) {.async.} =
  while b.discEngineRunning:
    for cid in toSeq(b.pendingBlocks.wantList):
      try:
        await b.discoveryQueue.put(cid)
      except CatchableError as exc:
        trace "Exception in discovery loop", exc = exc.msg

    trace "About to sleep, number of wanted blocks", wanted = b.pendingBlocks.len
    await sleepAsync(30.seconds)

proc advertiseLoopRunner*(b: DiscoveryEngine) {.async.} =
  proc onBlock(cid: Cid) {.async.} =
    try:
      await b.advertiseQueue.put(cid)
    except CatchableError as exc:
      trace "Exception listing blocks", exc = exc.msg

  while b.discEngineRunning:
    await b.localStore.listBlocks(onBlock)
    await sleepAsync(30.seconds)

  trace "Exiting advertise task loop"

proc advertiseTaskRunner(b: DiscoveryEngine) {.async.} =
  ## Run advertise tasks
  ##

  while b.discEngineRunning:
    try:
      let cid = await b.advertiseQueue.get()
      await b.discovery.provideBlock(cid)
    except CatchableError as exc:
      trace "Exception in advertise task runner", exc = exc.msg

  trace "Exiting advertise task runner"

proc discoveryTaskRunner(b: DiscoveryEngine) {.async.} =
  ## Run discovery tasks
  ##

  while b.discEngineRunning:
    try:
      let
        cid = await b.discoveryQueue.get()
      #   haves = b.peers.filterIt(
      #     it.peerHave.anyIt( it == cid )
      #   )

      # trace "Got peers for block", cid = $cid, count = haves.len
      # let
      #   providers =
      #     if haves.len < b.minPeersPerBlock:
      #       await b.discovery
      #         .findBlockProviders(cid)
      #         .wait(DefaultDiscoveryTimeout)
      #     else:
      #       @[]

      # checkFutures providers.mapIt( b.network.dialPeer(it.data) )
    except CatchableError as exc:
      trace "Exception in discovery task runner", exc = exc.msg

  trace "Exiting discovery task runner"

template queueFindBlocksReq*(b: DiscoveryEngine, cids: seq[Cid]) =
  proc queueReq() {.async.} =
    try:
      for cid in cids:
        if cid notin b.discoveryQueue:
          trace "Queueing find block request", cid = $cid
          await b.discoveryQueue.put(cid)
    except CatchableError as exc:
      trace "Exception queueing discovery request", exc = exc.msg

  asyncSpawn queueReq()

template queueProvideBlocksReq*(b: DiscoveryEngine, cids: seq[Cid]) =
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
    b.advertiseTasks.add(advertiseTaskRunner(b))

  for i in 0..<b.concurrentDiscReqs:
    b.discoveryTasks.add(discoveryTaskRunner(b))

  b.advertiseLoop = advertiseLoopRunner(b)
  b.discoveryLoop = discoveryLoopRunner(b)

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
  concurrentAdvReqs = DefaultConcurrentAdvertRequests,
  concurrentDiscReqs = DefaultConcurrentDiscRequests,
  minPeersPerBlock = DefaultMinPeersPerBlock): DiscoveryEngine =
  discard
