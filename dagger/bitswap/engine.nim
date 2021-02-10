## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/tables
import std/options

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/libp2p/errors

import ./protobuf/bitswap as pb
import ./network

import ../blocktype as bt
import ../stores/blockstore
import ../utils/asyncheapqueue

const
  DefaultTimeout = 500.milliseconds

type
  BitswapPeerCtx* = ref object of RootObj
    id: PeerID
    sentWants: seq[Cid]               # peers we've sent WANTs recently
    peerHave: seq[Cid]                # remote peers have lists
    peerWants: AsyncHeapQueue[Entry]  # remote peers want lists
    bytesSent: int                    # bytes sent to remote
    bytesRecv: int                    # bytes received from remote
    exchanged: int                    # times peer has exchanged with us
    lastExchange: Moment              # last time peer has exchanged with us

  BitswapEngine* = ref object of RootObj
    store: BlockStore                           # where we store blocks for this instance
    network: BitswapNetwork                     # our network interface to send/recv blocks
    peers: seq[BitswapPeerCtx]                  # peers we're currently activelly exchanging with
    wantList: seq[Cid]                          # local wants list
    pendingBlocks: Table[Cid, Future[bt.Block]] # pending bt.Block requests

proc contains*(a: openarray[BitswapPeerCtx], b: PeerID): bool {.inline.} =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.id == b ).len > 0

proc cid(e: Entry): Cid {.inline.} =
  ## Helper to conver raw bytes to Cid
  ##

  Cid.init(e.`block`).get()

proc contains*(a: openarray[Entry], b: Cid): bool {.inline.} =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.cid == b ).len > 0

proc `==`*(a: Entry, cid: Cid): bool {.inline.} =
  return a.cid == cid

proc contains[T](a: AsyncHeapQueue[T], b: Cid): bool {.inline.} =
  ## Convenience method to check for entry precense
  ##

  a.filterIt( it.cid == b ).len > 0

proc debtRatio(b: BitswapPeerCtx): float =
  b.bytesSent / (b.bytesRecv + 1)

proc `<`(a, b: BitswapPeerCtx): bool =
  a.debtRatio < b.debtRatio

proc `<`(a, b: Entry): bool =
  a.priority < b.priority

proc getPeerCtx(b: BitswapEngine, peerId: PeerID): BitswapPeerCtx {.inline} =
  ## Get the peer's context
  ##

  let peer = b.peers.filterIt( it.id == peerId )
  if peer.len > 0:
    return peer[0]

proc addBlockEvent(
  b: BitswapEngine,
  cid: Cid,
  timeout = DefaultTimeout): Future[bt.Block] {.async.} =
  ## Add an inflight block to wait list
  ##

  var pendingBlock: Future[bt.Block]
  var pendingList = b.pendingBlocks

  if cid in pendingList:
    pendingBlock = pendingList[cid]
  else:
    pendingBlock = newFuture[bt.Block]().wait(timeout)
    pendingList[cid] = pendingBlock

  try:
    return await pendingBlock
  except CatchableError as exc:
    trace "Pending WANT failed or expired", exc = exc.msg
    pendingList.del(cid)

proc requestBlocks*(
  b: BitswapEngine,
  cids: seq[Cid]):
  Future[seq[Option[bt.Block]]] {.async.} =
  ## Request a block from remotes
  ##

  if b.peers.len <= 0:
    warn "No peers to request blocks from"
    # TODO: run discovery here to get peers for the block
    return

  # add events for pending blocks
  var blocks = cids.mapIt( b.addBlockEvent(it) )

  let peerCtx = b.peers[0]
  # attempt to get the block from the a peer
  await b.network.sendWantList(
    peerCtx.id,
    cids,
    wantType = WantType.wantBlock)

  proc sendWants(info: BitswapPeerCtx) {.async.} =
    # TODO: check `ctx.sentList` that we havent
    # sent a WANT already and only send if we
    # haven't
    await b.network.sendWantList(
      info.id, cids, wantType = WantType.wantHave)

  var pending: seq[Future[void]]

  var i = 1
  while i <= b.peers.len:
    pending.add(sendWants(b.peers[i]))

  # send a WANT message to all other peers
  checkFutures(await allFinished(pending))

  let resolvedBlocks = await allFinished(blocks) # return pending blocks
  return resolvedBlocks.mapIt(
    if it.finished and not it.failed:
      some(it.read)
    else:
      none(bt.Block)
  )

proc blockPresenceHandler*(
  b: BitswapEngine,
  peer: PeerID,
  presence: seq[BlockPresence]) =
  ## Handle block presence
  ##

  let peerCtx = b.getPeerCtx(peer)
  if not isNil(peerCtx):
    for blk in presence:
      let cid = Cid.init(blk.cid).get()

      if not isNil(peerCtx):
        if cid notin peerCtx.peerHave:
          if blk.type == BlockPresenceType.presenceHave:
            peerCtx.peerHave.add(cid)

proc blocksHandler*(
  b: BitswapEngine,
  peer: PeerID,
  blocks: seq[bt.Block]) =
  ## handle incoming blocks
  ##
  b.store.putBlocks(blocks)

proc wantListHandler*(
  b: BitswapEngine,
  peer: PeerID,
  entries: seq[pb.Entry]) =
  ## Handle incoming want lists
  ##

  let peerCtx = b.getPeerCtx(peer)
  var dontHaves: seq[Cid]
  if not isNil(peerCtx):
    for e in entries:
      let ccid = e.cid
      # peer doesn't want this block anymore
      if ccid in peerCtx.peerWants and e.cancel:
        let i = peerCtx.peerWants.find(ccid)
        if i > -1:
          peerCtx.peerWants.del(i)
      elif ccid notin peerCtx.peerWants:
        peerCtx.peerWants.pushNoWait(e)
        if e.sendDontHave and not(b.store.hasBlock(ccid)):
          dontHaves.add(ccid)

  # send don't have's to remote
  if dontHaves.len > 0:
    b.network.sendBlockPresense(
      peer,
      dontHaves.mapIt(
        BlockPresence(
          cid: it.data.buffer,
          `type`: BlockPresenceType.presenceDontHave)))

proc setupPeer*(b: BitswapEngine, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  if peer notin b.peers:
    b.peers.add(BitswapPeerCtx(
      id: peer,
      peerWants: newAsyncHeapQueue[Entry]()
    ))

  # broadcast our want list, the other peer will do the same
  asyncCheck b.network.sendWantList(peer, b.wantList, full = true)

proc dropPeer*(b: BitswapEngine, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  # drop the peer from the peers table
  b.peers.keepItIf( it.id != peer )

proc new*(T: type BitswapEngine, store: BlockStore, network: BitswapNetwork): T =

  let b = BitswapEngine(
    store: store,
    network: network,
    pendingBlocks: initTable[Cid, Future[bt.Block]]())

  proc onBlocks(evt: BlockStoreChangeEvt) =
    if evt.kind == ChangeType.Added:
      for blk in evt.blocks:
        # resolve any pending blocks
        if blk.cid in b.pendingBlocks:
          let pending = b.pendingBlocks[blk.cid]
          if not pending.finished:
            pending.complete(blk)
            b.pendingBlocks.del(blk.cid)

  store.addChangeHandler(onBlocks, ChangeType.Added)

  proc blockPresenceHandler(
    peer: PeerID,
    presence: seq[BlockPresence]) {.gcsafe.} =
    asyncCheck b.blockPresenceHandler(peer, presence)

  proc blockHandler(
    peer: PeerID,
    blocks: seq[Block]) {.gcsafe.} =
    asyncCheck b.blockHandler(peer, blocks)

  b.network.onBlockHandler = blockHandler
  b.network.onBlockPresence = blockPresenceHandler
  return b
