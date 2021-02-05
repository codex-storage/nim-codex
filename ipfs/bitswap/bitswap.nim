## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/sequtils
import std/heapqueue
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors
import pkg/libp2p/switch

import ./protobuf/bitswap as pb
import ../blocktype as bt
import ../blockstore
import ./network

const
  MaxSessionPeers = 10
  DefaultTimeout = 500.milliseconds

type
  BitswapInfo* = object
    sentHaves: seq[Cid]                # peers we've sent WANTs recently
    peersHave: seq[Cid]                # remote peers have lists
    peersWants: seq[Cid]               # remote peers want lists

  Bitswap* = ref object of BlockProvider
    store: BlockStore
    network: BitswapNetwork
    peers: Table[PeerID, BitswapInfo]
    wantList: seq[Cid]                                # our pending wants
    # TODO: use a heapqueue instead of seq
    session: seq[PeerID]                              # peers currently exchanging blocks
    waitList: Table[PeerID, Table[Cid, Future[void]]] # pending WANT requests

proc addBlockEvent(
  b: Bitswap,
  id: PeerID,
  cid: Cid,
  timeout = DefaultTimeout): Future[PeerID] {.async.} =
  ## add an inflight block to wait list
  ##

  var peerList = b.waitList.mgetOrPut(id, initTable[Cid, Future[void]]())
  let fut = newFuture[void]().wait(timeout)
  peerList[cid] = fut

  try:
    await fut
    return id
  except CatchableError as exc:
    trace "Pending block failed or expired", exc = exc.msg
    peerList.del(cid)

proc createSession(b: Bitswap, cid: Cid) {.async.} =
  ## Create a session with MaxSessionPeers
  ##

  if cid notin b.wantList:
    b.wantList.add(cid)

  let pending: seq[Future[void]]
  for p in toSeq(b.peers.keys):
    pending.add(b.addBlockEvent(p, cid))
    asyncCheck b.network.sendWantList(p, cid)

  let peerFuts = await allFinished(pending)
  var peers: seq[PeerID]
  # TODO: Randomize peers
  for p in peerFuts:
    if not p.failed:
      peers.add(p.read)

    if peers.len >= MaxSessionPeers:
      break

proc getBlockFromSession(b: Bitswap, cid: Cid): Future[bt.Block] {.async.} =
  if b.session.len <= 0:
    await b.createSession(cid) # wait for session to be created

  if b.session.len <= 0:
    warn "Couldn't get any peers to get blocks from"

  let blockPeer = b.session[0] # TODO: this should be a heapqueu
  # get the block from the best peer
  await b.network.sendWantList(
    blockPeer,
    cid,
    wantType = WantType.wantBlock)

  await checkFutures(
    allFinished(b.session[1..b.session.high]
    .map(proc(id: PeerID) =
      let info = h.peers[peer]
      if cid notin info.sentHaves[id]:
        b.network.sendWantList(id, cid, wantType = WantType.wantHave))))

method getBlock*(b: Bitswap, cid: Cid): Future[bt.Block] =
  discard

method hasBlock*(b: Bitswap, cid: Cid): bool =
  discard

proc setupPeer(b: Bitswap, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

proc dropPeer(b: Bitswap, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  b.peers.del(peer)
  if waiting in toSeq(b.waitList.values):
    for f in toSeq(waiting.values):
      if not f.finished:
        f.cancel()

proc new*(T: type Bitswap, store: BlockStore, network: BitswapNetwork): T =

  proc onBlocks(blocks: seq[Block]) =
    discard

  store.addChangeHandler(onBlocks)

  let b = Bitswap(
    store: store,
    network: network,
    waitList: initTable[Table[PeerID, Table[Cid, Future[void]]]])

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      b.setupPeer(peerId)
    else:
      b.dropPeer(peerId)

  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc wantListHandler(peer: PeerID, wantList: WantList) {.gcsafe.} =
    for list in wantList.entries:
      let cid = Cid.init(list.`block`)
      var info = b.peers[peer]
      if peer in b.waitList:
        var list = b.waitList[peer]
        if cid in list:
          list[cid].complete(peer)

  return b
