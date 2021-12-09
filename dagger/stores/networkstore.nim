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

import ../blocktype as bt
import ../utils/asyncfutures
import ../utils/asyncheapqueue

import ./blockstore
import ../blockexchange/network
import ../blockexchange/engine
import ../blockexchange/peercontext
import ../blockexchange/protobuf/blockexc as pb

export blockstore, network, engine, asyncheapqueue

logScope:
  topics = "dagger blockexc"

const
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  DefaultMaxRetries = 3

type
  NetworkStore* = ref object of BlockStore
    engine*: BlockExcEngine                       # blockexc decision engine
    localStore*: BlockStore                       # local block store
    taskQueue*: AsyncHeapQueue[BlockExcPeerCtx]   # peers we're currently processing tasks for
    blockexcTasks: seq[Future[void]]              # future to control blockexc task
    blockexcRunning: bool                         # indicates if the blockexc task is running
    concurrentTasks: int                          # number of concurrent peers we're serving at any given time
    maxRetries: int                               # max number of tries for a failed block
    taskHandler: TaskHandler                      # handler provided by the engine called by the runner

proc blockexcTaskRunner(b: NetworkStore) {.async.} =
  ## process tasks
  ##

  while b.blockexcRunning:
    let peerCtx = await b.taskQueue.pop()
    asyncSpawn b.taskHandler(peerCtx)

  trace "Exiting blockexc task runner"

proc start*(b: NetworkStore) {.async.} =
  ## Start the blockexc task
  ##

  trace "blockexc start"

  if b.blockexcTasks.len > 0:
    warn "Starting blockexc twice"
    return

  b.blockexcRunning = true
  for i in 0..<b.concurrentTasks:
    b.blockexcTasks.add(b.blockexcTaskRunner)

proc stop*(b: NetworkStore) {.async.} =
  ## Stop the blockexc blockexc
  ##

  trace "NetworkStore stop"
  if b.blockexcTasks.len <= 0:
    warn "Stopping blockexc without starting it"
    return

  b.blockexcRunning = false
  for t in b.blockexcTasks:
    if not t.finished:
      trace "Awaiting task to stop"
      t.cancel()
      trace "Task stopped"

  trace "NetworkStore stopped"

method getBlock*(
  b: NetworkStore,
  cid: Cid): Future[?bt.Block] {.async.} =
  ## Get a block from a remote peer
  ##

  without blk =? (await b.localStore.getBlock(cid)):
    return await b.engine.requestBlock(cid)

  return blk.some

method putBlock*(
  b: NetworkStore,
  blk: bt.Block) {.async.} =
  await b.localStore.putBlock(blk)
  b.engine.resolveBlocks(@[blk])

proc new*(
  T: type NetworkStore,
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

  let b = NetworkStore(
    localStore: localStore,
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

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    # TODO: temporary until libp2p moves back to PeerID
    if event.kind == PeerEventKind.Joined:
      b.engine.setupPeer(peerId)
    else:
      b.engine.dropPeer(peerId)

  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockWantListHandler(
    peer: PeerID,
    wantList: WantList): Future[void] {.gcsafe.} =
    engine.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
    peer: PeerID,
    presence: seq[BlockPresence]): Future[void] {.gcsafe.} =
    engine.blockPresenceHandler(peer, presence)

  proc blocksHandler(
    peer: PeerID,
    blocks: seq[bt.Block]): Future[void] {.gcsafe.} =
    engine.blocksHandler(peer, blocks)

  proc accountHandler(peer: PeerId, account: Account): Future[void] {.gcsafe.} =
    engine.accountHandler(peer, account)

  proc paymentHandler(peer: PeerId, payment: SignedState): Future[void] {.gcsafe.} =
    engine.paymentHandler(peer, payment)

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onBlocks: blocksHandler,
    onPresence: blockPresenceHandler,
    onAccount: accountHandler,
    onPayment: paymentHandler
  )

  return b
