## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/hashes
import std/heapqueue
import std/options
import std/tables
import std/sequtils
import std/heapqueue

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import ./protobuf/bitswap as pb
import ../blocktype as bt
import ../stores/blockstore
import ../utils/asyncheapqueue

import ./network
import ./pendingblocks

export network, blockstore

const
  DefaultTimeout = 500.milliseconds
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10

type
  BitswapPeerCtx* = ref object of RootObj
    id*: PeerID
    peerHave*: seq[Cid]                # remote peers have lists
    peerWants*: AsyncHeapQueue[Entry]  # remote peers want lists
    bytesSent*: int                    # bytes sent to remote
    bytesRecv*: int                    # bytes received from remote
    exchanged*: int                    # times peer has exchanged with us
    lastExchange*: Moment              # last time peer has exchanged with us

  Bitswap* = ref object of BlockStore
    storeManager: BlockStore                    # where we storeManager blocks for this instance
    network: BitswapNetwork                     # our network interface to send/recv blocks
    peers: seq[BitswapPeerCtx]                  # peers we're currently activelly exchanging with
    wantList: seq[Cid]                          # local wants list
    pendingBlocks: PendingBlocksManager         # blocks we're awaiting to be resolved
    taskQueue: AsyncHeapQueue[BitswapPeerCtx]   # peers we're currently processing tasks for

    # TODO: probably a good idea to have several
    # tasks running in parallel
    bitswapTasks: seq[Future[void]]             # future to control bitswap task
    bitswapRunning: bool                        # indicates if the bitswap task is running
    concurrentTasks: int                        # number of concurrent peers we're serving at any given time

proc contains*(a: AsyncHeapQueue[Entry], b: Cid): bool =
  ## Convenience method to check for entry precense
  ##

  a.filterIt( it.cid == b ).len > 0

proc contains*(a: openarray[BitswapPeerCtx], b: PeerID): bool =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.id == b ).len > 0

proc debtRatio(b: BitswapPeerCtx): float =
  b.bytesSent / (b.bytesRecv + 1)

proc `<`*(a, b: BitswapPeerCtx): bool =
  a.debtRatio < b.debtRatio

proc getPeerCtx*(b: Bitswap, peerId: PeerID): BitswapPeerCtx =
  ## Get the peer's context
  ##

  let peer = b.peers.filterIt( it.id == peerId )
  if peer.len > 0:
    return peer[0]

proc bitswapTaskRunner(b: Bitswap) {.async.} =
  ## process tasks in order of least amount of
  ## debt ratio
  ##

  while b.bitswapRunning:
    let peerCtx = await b.taskQueue.pop()
    var wantsBlocks, wantsWants: seq[Entry]
    # get blocks and wants to send to the remote
    while peerCtx.peerWants.len > 0:
      let e = await peerCtx.peerWants.pop()
      if e.wantType == WantType.wantBlock:
        wantsBlocks.add(e)
      else:
        wantsWants.add(e)

    # TODO: There should be all sorts of accounting of
    # bytes sent/received here
    if wantsWants.len > 0:
      let blocks = await b.storeManager.getBlocks(
        wantsBlocks.mapIt(
          it.cid
      ))

      b.network.broadcastBlocks(peerCtx.id, blocks)

    if wantsWants.len > 0:
      let haves = wantsWants.filterIt(
        b.storeManager.hasBlock(it.cid)
      ).mapIt(
        it.cid
      )

      b.network.broadcastBlockPresence(
        peerCtx.id, haves.mapIt(
          BlockPresence(
            cid: it.data.buffer,
            `type`: BlockPresenceType.presenceHave
          )
      ))

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
      await t
      trace "Task stopped"

  trace "Bitswap stopped"

proc requestBlocks*(
  b: Bitswap,
  cids: seq[Cid],
  timeout = DefaultTimeout):
  Future[seq[Option[bt.Block]]] {.async.} =
  ## Request a block from remotes
  ##

  if b.peers.len <= 0:
    warn "No peers to request blocks from"
    # TODO: run discovery here to get peers for the block
    return

  var blocks: seq[Future[bt.Block]] # this are blocks that we need right now
  var wantCids: seq[Cid] # filter out Cids that we're already waiting on
  for c in cids:
    if c notin b.pendingBlocks:
      wantCids.add(c)
      blocks.add(
        b.pendingBlocks.addOrAwait(c)
        .wait(timeout))

  # no Cids to request
  if wantCids.len == 0:
    return

  let peerCtx = b.peers[0]
  # attempt to get the block from the
  # peer with the least debt ratio
  b.network.broadcastWantList(
    peerCtx.id,
    wantCids,
    wantType = WantType.wantBlock) # we want this remote to send us a block

  template sendWants(ctx: BitswapPeerCtx) =
    b.network.broadcastWantList(
      ctx.id,
      wantCids.filterIt( it notin ctx.peerHave ), # filter out those that we already know about
      wantType = WantType.wantHave) # we only want to know if the peer has the block

  # send a want-have to all other peers,
  # ie starting from 1
  for i in 1..<b.peers.len:
    sendWants(b.peers[i])

  # TODO: Move this out, so this proc doesn't need to be async
  # send a WANT message to all other peers
  let resolvedBlocks = await allFinished(blocks) # return pending blocks
  return resolvedBlocks.mapIt(
    if it.finished and not it.failed:
      some(it.read)
    else:
      none(bt.Block)
  )

proc blockPresenceHandler*(
  b: Bitswap,
  peer: PeerID,
  presence: seq[BlockPresence]) =
  ## Handle block presence
  ##

  let peerCtx = b.getPeerCtx(peer)
  if isNil(peerCtx):
    return

  for blk in presence:
    let cid = Cid.init(blk.cid).get()
    if cid notin peerCtx.peerHave:
      if blk.type == BlockPresenceType.presenceHave:
        peerCtx.peerHave.add(cid)

proc blocksHandler*(
  b: Bitswap,
  peer: PeerID,
  blocks: seq[bt.Block]) =
  ## handle incoming blocks
  ##

  b.storeManager.putBlocks(blocks)
  b.pendingBlocks.resolvePending(blocks)

proc wantListHandler*(
  b: Bitswap,
  peer: PeerID,
  wantList: WantList) =
  ## Handle incoming want lists
  ##

  let peerCtx = b.getPeerCtx(peer)
  if isNil(peerCtx):
    return

  var dontHaves: seq[Cid]
  let entries = wantList.entries
  for e in entries:
    # peer doesn't want this block anymore
    if e.cid in peerCtx.peerWants and e.cancel:
      peerCtx.peerWants.delete(e)
    elif e.cid notin peerCtx.peerWants:
      if peerCtx.peerWants.pushOrUpdateNoWait(e).isOk:
        if e.sendDontHave and not(b.storeManager.hasBlock(e.cid)):
          dontHaves.add(e.cid)

  # send don't have's to remote
  if dontHaves.len > 0:
    b.network.broadcastBlockPresence(
      peer,
      dontHaves.mapIt(
        BlockPresence(
          cid: it.data.buffer,
          `type`: BlockPresenceType.presenceDontHave)))

  asyncSpawn b.taskQueue.pushOrUpdate(peerCtx)

proc setupPeer*(b: Bitswap, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  if peer notin b.peers:
    b.peers.add(BitswapPeerCtx(
      id: peer,
      peerWants: newAsyncHeapQueue[Entry]()
    ))

  # broadcast our want list, the other peer will do the same
  b.network.broadcastWantList(peer, b.wantList, full = true)

proc dropPeer*(b: Bitswap, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  # drop the peer from the peers table
  b.peers.keepItIf( it.id != peer )

method getBlocks*(b: Bitswap, cid: seq[Cid]): Future[seq[bt.Block]] {.async.} =
  ## Get a block from a remote peer
  ##

  let blocks = await b.requestBlocks(cid)
  return blocks.filterIt(
    it.isSome
  ).mapIt(
    it.get
  )

proc new*(
  T: type Bitswap,
  storeManager: BlockStore,
  network: BitswapNetwork,
  concurrentTasks = DefaultConcurrentTasks): T =

  let b = Bitswap(
    storeManager: storeManager,
    network: network,
    pendingBlocks: PendingBlocksManager.new(),
    taskQueue: newAsyncHeapQueue[BitswapPeerCtx](),
    concurrentTasks: concurrentTasks,
  )

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      b.setupPeer(peerId)
    else:
      b.dropPeer(peerId)

  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc onBlocks(evt: BlockStoreChangeEvt) =
    doAssert(evt.kind == ChangeType.Added,
      "change handler called for invalid event type")
    # TODO: need to retrieve blocks from storeManager but need
    # to be careful not to endup calling ourself in a
    # loop - this should not happen, but want to add
    # more check before adding this logic.

  storeManager.addChangeHandler(onBlocks, ChangeType.Added)

  proc blockWantListHandler(
    peer: PeerID,
    wantList: WantList) {.gcsafe.} =
    b.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
    peer: PeerID,
    presence: seq[BlockPresence]) {.gcsafe.} =
    b.blockPresenceHandler(peer, presence)

  proc blocksHandler(
    peer: PeerID,
    blocks: seq[bt.Block]) {.gcsafe.} =
    b.blocksHandler(peer, blocks)

  b.network.onWantList = blockWantListHandler
  b.network.onBlocks = blocksHandler
  b.network.onBlockPresence = blockPresenceHandler

  return b
