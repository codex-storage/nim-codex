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
import pkg/libp2p/cid
import pkg/libp2p/multicodec
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ./pendingblocks

import ../protobuf/presence
import ../network
import ../peers

import ../../utils
import ../../utils/trackedfutures
import ../../discovery
import ../../stores/blockstore
import ../../logutils
import ../../manifest

logScope:
  topics = "codex discoveryengine"

declareGauge(codex_inflight_discovery, "inflight discovery requests")

const
  DefaultConcurrentDiscRequests = 10
  DefaultDiscoveryTimeout = 1.minutes
  DefaultMinPeersPerBlock = 3
  DefaultDiscoveryLoopSleep = 3.seconds

type DiscoveryEngine* = ref object of RootObj
  localStore*: BlockStore # Local block store for this instance
  peers*: PeerCtxStore # Peer context store
  network*: BlockExcNetwork # Network interface
  discovery*: Discovery # Discovery interface
  pendingBlocks*: PendingBlocksManager # Blocks we're awaiting to be resolved
  discEngineRunning*: bool # Indicates if discovery is running
  concurrentDiscReqs: int # Concurrent discovery requests
  discoveryLoop*: Future[void].Raising([]) # Discovery loop task handle
  discoveryQueue*: AsyncQueue[Cid] # Discovery queue
  trackedFutures*: TrackedFutures # Tracked Discovery tasks futures
  minPeersPerBlock*: int # Max number of peers with block
  discoveryLoopSleep: Duration # Discovery loop sleep
  inFlightDiscReqs*: Table[Cid, Future[seq[SignedPeerRecord]]]
    # Inflight discovery requests

proc discoveryQueueLoop(b: DiscoveryEngine) {.async: (raises: []).} =
  try:
    while b.discEngineRunning:
      for cid in toSeq(b.pendingBlocks.wantListBlockCids):
        await b.discoveryQueue.put(cid)

      await sleepAsync(b.discoveryLoopSleep)
  except CancelledError:
    trace "Discovery loop cancelled"

proc discoveryTaskLoop(b: DiscoveryEngine) {.async: (raises: []).} =
  ## Run discovery tasks
  ##

  try:
    while b.discEngineRunning:
      let cid = await b.discoveryQueue.get()

      if cid in b.inFlightDiscReqs:
        trace "Discovery request already in progress", cid
        continue

      let haves = b.peers.peersHave(cid)

      if haves.len < b.minPeersPerBlock:
        let request = b.discovery.find(cid)
        b.inFlightDiscReqs[cid] = request
        codex_inflight_discovery.set(b.inFlightDiscReqs.len.int64)

        defer:
          b.inFlightDiscReqs.del(cid)
          codex_inflight_discovery.set(b.inFlightDiscReqs.len.int64)

        if (await request.withTimeout(DefaultDiscoveryTimeout)) and
            peers =? (await request).catch:
          let dialed = await allFinished(peers.mapIt(b.network.dialPeer(it.data)))

          for i, f in dialed:
            if f.failed:
              await b.discovery.removeProvider(peers[i].data.peerId)
  except CancelledError:
    trace "Discovery task cancelled"
    return

  info "Exiting discovery task runner"

proc queueFindBlocksReq*(b: DiscoveryEngine, cids: seq[Cid]) =
  for cid in cids:
    if cid notin b.discoveryQueue:
      try:
        b.discoveryQueue.putNoWait(cid)
      except CatchableError as exc:
        warn "Exception queueing discovery request", exc = exc.msg

proc start*(b: DiscoveryEngine) {.async: (raises: []).} =
  ## Start the discengine task
  ##

  trace "Discovery engine starting"

  if b.discEngineRunning:
    warn "Starting discovery engine twice"
    return

  b.discEngineRunning = true
  for i in 0 ..< b.concurrentDiscReqs:
    let fut = b.discoveryTaskLoop()
    b.trackedFutures.track(fut)

  b.discoveryLoop = b.discoveryQueueLoop()
  b.trackedFutures.track(b.discoveryLoop)

  trace "Discovery engine started"

proc stop*(b: DiscoveryEngine) {.async: (raises: []).} =
  ## Stop the discovery engine
  ##

  trace "Discovery engine stop"
  if not b.discEngineRunning:
    warn "Stopping discovery engine without starting it"
    return

  b.discEngineRunning = false
  trace "Stopping discovery loop and tasks"
  await b.trackedFutures.cancelTracked()
  trace "Discovery loop and tasks stopped"

  trace "Discovery engine stopped"

proc new*(
    T: type DiscoveryEngine,
    localStore: BlockStore,
    peers: PeerCtxStore,
    network: BlockExcNetwork,
    discovery: Discovery,
    pendingBlocks: PendingBlocksManager,
    concurrentDiscReqs = DefaultConcurrentDiscRequests,
    discoveryLoopSleep = DefaultDiscoveryLoopSleep,
    minPeersPerBlock = DefaultMinPeersPerBlock,
): DiscoveryEngine =
  ## Create a discovery engine instance for advertising services
  ##
  DiscoveryEngine(
    localStore: localStore,
    peers: peers,
    network: network,
    discovery: discovery,
    pendingBlocks: pendingBlocks,
    concurrentDiscReqs: concurrentDiscReqs,
    discoveryQueue: newAsyncQueue[Cid](concurrentDiscReqs),
    trackedFutures: TrackedFutures.new(),
    inFlightDiscReqs: initTable[Cid, Future[seq[SignedPeerRecord]]](),
    discoveryLoopSleep: discoveryLoopSleep,
    minPeersPerBlock: minPeersPerBlock,
  )
