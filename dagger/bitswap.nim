## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import ./bitswap/protobuf/bitswap as pb
import ./blocktype as bt
import ./stores/blockstore
import ./utils/asyncheapqueue

import ./bitswap/network
import ./bitswap/engine

export network, blockstore, asyncheapqueue, engine

logScope:
  topics = "dagger bitswap"

const
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  DefaultMaxRetries = 3

type
  Bitswap* = ref object of BlockStore
    engine*: BitswapEngine                       # bitswap decision engine
    taskQueue*: AsyncHeapQueue[BitswapPeerCtx]   # peers we're currently processing tasks for
    bitswapTasks: seq[Future[void]]              # future to control bitswap task
    bitswapRunning: bool                         # indicates if the bitswap task is running
    concurrentTasks: int                         # number of concurrent peers we're serving at any given time
    maxRetries: int                              # max number of tries for a failed block
    taskHandler: TaskHandler                     # handler provided by the engine called by the runner

proc bitswapTaskRunner(b: Bitswap) {.async.} =
  ## process tasks in order of least amount of
  ## debt ratio
  ##

  while b.bitswapRunning:
    let peerCtx = await b.taskQueue.pop()
    asyncSpawn b.taskHandler(peerCtx)

  trace "Exiting bitswap task runner"

proc start*(b: Bitswap) {.async.} =
  ## Start the bitswap task
  ##

  trace "bitswap start"

  if b.bitswapTasks.len > 0:
    warn "Starting bitswap twice"
    return

  b.bitswapRunning = true
  for i in 0..<b.concurrentTasks:
    b.bitswapTasks.add(b.bitswapTaskRunner)

proc stop*(b: Bitswap) {.async.} =
  ## Stop the bitswap bitswap
  ##

  trace "Bitswap stop"
  if b.bitswapTasks.len <= 0:
    warn "Stopping bitswap without starting it"
    return

  b.bitswapRunning = false
  for t in b.bitswapTasks:
    if not t.finished:
      trace "Awaiting task to stop"
      t.cancel()
      trace "Task stopped"

  trace "Bitswap stopped"

method getBlocks*(b: Bitswap, cid: seq[Cid]): Future[seq[bt.Block]] {.async.} =
  ## Get a block from a remote peer
  ##

  let blocks = await allFinished(b.engine.requestBlocks(cid))
  return blocks.filterIt(
    not it.failed
  ).mapIt(
    it.read
  )

method putBlocks*(b: Bitswap, blocks: seq[bt.Block]) =
  b.engine.resolveBlocks(blocks)

  procCall BlockStore(b).putBlocks(blocks)

proc new*(
  T: type Bitswap,
  localStore: BlockStore,
  wallet: WalletRef,
  network: BitswapNetwork,
  concurrentTasks = DefaultConcurrentTasks,
  maxRetries = DefaultMaxRetries,
  peersPerRequest = DefaultMaxPeersPerRequest): T =

  let engine = BitswapEngine.new(
    localStore = localStore,
    wallet = wallet,
    peersPerRequest = peersPerRequest,
    request = network.request,
  )

  let b = Bitswap(
    engine: engine,
    taskQueue: newAsyncHeapQueue[BitswapPeerCtx](DefaultTaskQueueSize),
    concurrentTasks: concurrentTasks,
    maxRetries: maxRetries,
  )

  # attach engine's task handler
  b.taskHandler = proc(task: BitswapPeerCtx):
    Future[void] {.gcsafe.} =
    engine.taskHandler(task)

  # attach task scheduler to engine
  engine.scheduleTask = proc(task: BitswapPeerCtx):
    bool {.gcsafe} =
    b.taskQueue.pushOrUpdateNoWait(task).isOk()

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      b.engine.setupPeer(peerId)
    else:
      b.engine.dropPeer(peerId)

  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockWantListHandler(
    peer: PeerID,
    wantList: WantList) {.gcsafe.} =
    engine.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
    peer: PeerID,
    presence: seq[BlockPresence]) {.gcsafe.} =
    engine.blockPresenceHandler(peer, presence)

  proc blocksHandler(
    peer: PeerID,
    blocks: seq[bt.Block]) {.gcsafe.} =
    engine.blocksHandler(peer, blocks)

  proc pricingHandler(peer: PeerId, pricing: Pricing) =
    engine.pricingHandler(peer, pricing)

  proc paymentHandler(peer: PeerId, payment: SignedState) =
    engine.paymentHandler(peer, payment)

  network.handlers = BitswapHandlers(
    onWantList: blockWantListHandler,
    onBlocks: blocksHandler,
    onPresence: blockPresenceHandler,
    onPricing: pricingHandler,
    onPayment: paymentHandler
  )

  return b
