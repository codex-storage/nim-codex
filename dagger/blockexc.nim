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

import ./stores/network/protobuf/blockexc as pb
import ./blocktype as bt
import ./stores/blockstore
import ./utils/asyncheapqueue

import ./stores/network/network
import ./stores/network/engine

export network, blockstore, asyncheapqueue, engine

logScope:
  topics = "dagger blockexc"

const
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  DefaultMaxRetries = 3

type
  BlockExc* = ref object of BlockStore
    engine*: BlockExcEngine                       # blockexc decision engine
    taskQueue*: AsyncHeapQueue[BlockExcPeerCtx]   # peers we're currently processing tasks for
    blockexcTasks: seq[Future[void]]              # future to control blockexc task
    blockexcRunning: bool                         # indicates if the blockexc task is running
    concurrentTasks: int                         # number of concurrent peers we're serving at any given time
    maxRetries: int                              # max number of tries for a failed block
    taskHandler: TaskHandler                     # handler provided by the engine called by the runner

proc blockexcTaskRunner(b: BlockExc) {.async.} =
  ## process tasks
  ##

  while b.blockexcRunning:
    let peerCtx = await b.taskQueue.pop()
    asyncSpawn b.taskHandler(peerCtx)

  trace "Exiting blockexc task runner"

proc start*(b: BlockExc) {.async.} =
  ## Start the blockexc task
  ##

  trace "blockexc start"

  if b.blockexcTasks.len > 0:
    warn "Starting blockexc twice"
    return

  b.blockexcRunning = true
  for i in 0..<b.concurrentTasks:
    b.blockexcTasks.add(b.blockexcTaskRunner)

proc stop*(b: BlockExc) {.async.} =
  ## Stop the blockexc blockexc
  ##

  trace "BlockExc stop"
  if b.blockexcTasks.len <= 0:
    warn "Stopping blockexc without starting it"
    return

  b.blockexcRunning = false
  for t in b.blockexcTasks:
    if not t.finished:
      trace "Awaiting task to stop"
      t.cancel()
      trace "Task stopped"

  trace "BlockExc stopped"

method getBlocks*(b: BlockExc, cid: seq[Cid]): Future[seq[bt.Block]] {.async.} =
  ## Get a block from a remote peer
  ##

  let blocks = await allFinished(b.engine.requestBlocks(cid))
  return blocks.filterIt(
    not it.failed
  ).mapIt(
    it.read
  )

method putBlocks*(b: BlockExc, blocks: seq[bt.Block]) =
  b.engine.resolveBlocks(blocks)

  procCall BlockStore(b).putBlocks(blocks)

proc new*(
  T: type BlockExc,
  localStore: BlockStore,
  wallet: WalletRef,
  network: BlockExcNetwork,
  concurrentTasks = DefaultConcurrentTasks,
  maxRetries = DefaultMaxRetries,
  peersPerRequest = DefaultMaxPeersPerRequest): T =

  let engine = BlockExcEngine.new(
    localStore = localStore,
    wallet = wallet,
    peersPerRequest = peersPerRequest,
    request = network.request,
  )

  let b = BlockExc(
    engine: engine,
    taskQueue: newAsyncHeapQueue[BlockExcPeerCtx](DefaultTaskQueueSize),
    concurrentTasks: concurrentTasks,
    maxRetries: maxRetries,
  )

  # attach engine's task handler
  b.taskHandler = proc(task: BlockExcPeerCtx): Future[void] {.gcsafe.} =
    engine.taskHandler(task)

  # attach task scheduler to engine
  engine.scheduleTask = proc(task: BlockExcPeerCtx): bool {.gcsafe} =
    b.taskQueue.pushOrUpdateNoWait(task).isOk()

  proc peerEventHandler(peerInfo: PeerInfo, event: PeerEvent) {.async.} =
    # TODO: temporary until libp2p moves back to PeerID
    let
      peerId = peerInfo.peerId

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

  proc accountHandler(peer: PeerId, account: Account) =
    engine.accountHandler(peer, account)

  proc paymentHandler(peer: PeerId, payment: SignedState) =
    engine.paymentHandler(peer, payment)

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onBlocks: blocksHandler,
    onPresence: blockPresenceHandler,
    onAccount: accountHandler,
    onPayment: paymentHandler
  )

  return b
