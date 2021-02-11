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
import ./pendingblocks

import ../blocktype as bt
import ../stores/blockstore
import ../utils/asyncheapqueue

const
  DefaultTimeout = 500.milliseconds

type
  BitswapPeerCtx* = ref object of RootObj
    id*: PeerID
    peerHave*: seq[Cid]                # remote peers have lists
    peerWants*: AsyncHeapQueue[Entry]  # remote peers want lists
    bytesSent*: int                    # bytes sent to remote
    bytesRecv*: int                    # bytes received from remote
    exchanged*: int                    # times peer has exchanged with us
    lastExchange*: Moment              # last time peer has exchanged with us

  BitswapEngine* = ref object of RootObj
    store: BlockStore                           # where we store blocks for this instance
    network: BitswapNetwork                     # our network interface to send/recv blocks
    peers: seq[BitswapPeerCtx]                  # peers we're currently activelly exchanging with
    wantList: seq[Cid]                          # local wants list
    pendingBlocks: PendingBlocksManager         # blocks we're awaiting to be resolved

proc contains[T](a: AsyncHeapQueue[T], b: Cid): bool {.inline.} =
  ## Convenience method to check for entry precense
  ##

  a.filterIt( it.cid == b ).len > 0

proc contains(a: openarray[BitswapPeerCtx], b: PeerID): bool {.inline.} =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.id == b ).len > 0

proc debtRatio(b: BitswapPeerCtx): float =
  b.bytesSent / (b.bytesRecv + 1)

proc `<`(a, b: BitswapPeerCtx): bool =
  a.debtRatio < b.debtRatio

proc getPeerCtx*(b: BitswapEngine, peerId: PeerID): BitswapPeerCtx {.inline} =
  ## Get the peer's context
  ##

  let peer = b.peers.filterIt( it.id == peerId )
  if peer.len > 0:
    return peer[0]

proc requestBlocks*(
  b: BitswapEngine,
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

  proc sendWants(ctx: BitswapPeerCtx) =
    b.network.broadcastWantList(
      ctx.id,
      wantCids.filterIt( it notin ctx.peerHave ), # filter out those that we already know about
      wantType = WantType.wantHave) # we only want to know if the peer has the block

  # send a want-have to all other peers,
  # ie starting from 1
  for i in 1..<b.peers.len:
    sendWants(b.peers[i])

  # send a WANT message to all other peers
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
  if isNil(peerCtx):
    return

  for blk in presence:
    let cid = Cid.init(blk.cid).get()
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
  b.pendingBlocks.resolvePending(blocks)

proc wantListHandler*(
  b: BitswapEngine,
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
      let i = peerCtx.peerWants.find(e.cid)
      if i > -1:
        peerCtx.peerWants.del(i)
    elif e.cid notin peerCtx.peerWants:
      peerCtx.peerWants.pushNoWait(e)
      if e.sendDontHave and not(b.store.hasBlock(e.cid)):
        dontHaves.add(e.cid)

  # send don't have's to remote
  if dontHaves.len > 0:
    b.network.broadcastBlockPresence(
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
  b.network.broadcastWantList(peer, b.wantList, full = true)

proc dropPeer*(b: BitswapEngine, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  # drop the peer from the peers table
  b.peers.keepItIf( it.id != peer )

proc new*(T: type BitswapEngine, store: BlockStore, network: BitswapNetwork): T =

  let b = BitswapEngine(
    store: store,
    network: network,
    pendingBlocks: PendingBlocksManager.new())

  proc onBlocks(evt: BlockStoreChangeEvt) =
    doAssert(evt.kind == ChangeType.Added,
      "change handler called for invalid event type")
    # TODO: need to retrieve blocks from store but need
    # to be careful not to endup calling ourself in a
    # loop - this should not happen, but want to add
    # more check before adding this logic.

  store.addChangeHandler(onBlocks, ChangeType.Added)

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
