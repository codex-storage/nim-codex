## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/hashes
import std/tables
import std/sequtils
import std/algorithm

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

export network, blockstore, asyncheapqueue

const
  DefaultTimeout = 500.milliseconds
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  DefaultMaxPeersPerRequest = 10
  DefaultMaxRetries = 3

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
    wantList*: seq[Cid]                         # local wants list
    pendingBlocks: PendingBlocksManager         # blocks we're awaiting to be resolved
    taskQueue*: AsyncHeapQueue[BitswapPeerCtx]   # peers we're currently processing tasks for

    # TODO: probably a good idea to have several
    # tasks running in parallel
    bitswapTasks: seq[Future[void]]             # future to control bitswap task
    bitswapRunning: bool                        # indicates if the bitswap task is running
    concurrentTasks: int                        # number of concurrent peers we're serving at any given time
    maxRetries: int                             # max number of tries for a failed block
    maxPeersPerRequest: int                     # max number of peers to request from

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
    if wantsBlocks.len > 0:
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
  timeout = DefaultTimeout): seq[Future[bt.Block]] =
  ## Request a block from remotes
  ##

  if b.peers.len <= 0:
    warn "No peers to request blocks from"
    # TODO: run discovery here to get peers for the block
    return

  var blocks: seq[Future[bt.Block]] # this are blocks that we need right now
  var wantCids: seq[Cid] # filter out Cids that we're already requested on
  for c in cids:
    if c notin b.pendingBlocks:
      wantCids.add(c)
      blocks.add(
        b.pendingBlocks.addOrAwait(c)
        .wait(timeout))

  # no Cids to request
  if wantCids.len == 0:
    return

  proc cmp(a, b: BitswapPeerCtx): int =
    if a.debtRatio == b.debtRatio:
      0
    elif a.debtRatio > b.debtRatio:
      1
    else:
      -1

  # sort it so we get it from the peer with the lowest
  # debt ratio
  var sortedPeers = b.peers.sorted(
    cmp
  )

  # get the first peer with at least one (any)
  # matching cid
  var peerCtx: BitswapPeerCtx
  var i = 0
  for p in sortedPeers:
    inc(i)
    if wantCids.anyIt(
      it in p.peerHave
    ): peerCtx = p; break

  # didnt find any peer with matching cids
  # use the first one in the sorted array
  if isNil(peerCtx):
    i = 1
    peerCtx = sortedPeers[0]

  b.network.broadcastWantList(
    peerCtx.id,
    wantCids,
    wantType = WantType.wantBlock) # we want this remote to send us a block

  template sendWants(ctx: BitswapPeerCtx) =
    b.network.broadcastWantList(
      ctx.id,
      wantCids.filterIt( it notin ctx.peerHave ), # filter out those that we already know about
      wantType = WantType.wantHave) # we only want to know if the peer has the block

  # filter out the peer we've already requested from
  var stop = sortedPeers.high
  if stop > b.maxPeersPerRequest:
    stop = b.maxPeersPerRequest

  for p in sortedPeers[i..stop]:
    sendWants(p)

  return blocks

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

  trace "got want list from peer", peer

  let peerCtx = b.getPeerCtx(peer)
  if isNil(peerCtx):
    return

  var dontHaves: seq[Cid]
  let entries = wantList.entries
  for e in entries:
    if e.cid in peerCtx.peerWants:
      # peer doesn't want this block anymore
      if e.cancel:
        peerCtx.peerWants.delete(e)
        continue
    else:
      if peerCtx.peerWants.pushOrUpdateNoWait(e).isErr:
        trace "Cant add want cid", cid = $e.cid

    # peer might want to ask for the same cid with
    # different want params
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

  let blocks = await allFinished(b.requestBlocks(cid))
  result.add(blocks.filterIt(
    not it.failed
  ).mapIt(
    it.read
  ))

proc new*(
  T: type Bitswap,
  storeManager: BlockStore,
  network: BitswapNetwork,
  concurrentTasks = DefaultConcurrentTasks,
  maxRetries = DefaultMaxRetries,
  maxPeersPerRequest = DefaultMaxPeersPerRequest): T =

  let b = Bitswap(
    storeManager: storeManager,
    network: network,
    pendingBlocks: PendingBlocksManager.new(),
    taskQueue: newAsyncHeapQueue[BitswapPeerCtx](DefaultTaskQueueSize),
    concurrentTasks: concurrentTasks,
    maxRetries: maxRetries,
    maxPeersPerRequest: maxPeersPerRequest,
  )

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      b.setupPeer(peerId)
    else:
      b.dropPeer(peerId)

  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc onBlocks(evt: BlockStoreChangeEvt) =
    if evt.kind != ChangeType.Added:
      return

    if b.taskQueue.full:
      return

    for c in evt.cids:
      for p in b.peers:
        if c in p.peerWants and p notin b.taskQueue:
          discard b.taskQueue.pushOrUpdateNoWait(p)

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
