## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sugar
import std/hashes
import std/tables
import std/sequtils
import std/heapqueue

import pkg/chronicles
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
  BitswapInfo* = ref object
    id: PeerID
    sentHaves: seq[Cid] # peers we've sent WANTs recently
    peerHave: seq[Cid]  # remote peers have lists
    peerWants: seq[Cid] # remote peers want lists

  Bitswap* = ref object of BlockProvider
    store: BlockStore
    network: BitswapNetwork
    peers: seq[BitswapInfo]
    wantList: seq[Cid]                                # our pending wants
    # TODO: use a heapqueue instead of seq
    session: seq[BitswapInfo]                         # peers currently exchanging blocks
    waitList: Table[PeerID, Table[Cid, Future[void]]] # pending WANT requests

# TODO: move to libp2p
proc hash*(cid: Cid): Hash {.inline.} =
  hash(cid.data.buffer)

proc contains*(a: openarray[BitswapInfo], b: PeerID): bool {.inline.} =
  a.filterIt( it.id == b ).len > 0

proc getInfo(b: Bitswap, peerId: PeerID): BitswapInfo {.inline} =
  let peer = b.peers.filterIt( it.id == peerId )
  if peer.len > 0:
    return peer[0]

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

  var pending: seq[Future[PeerID]]
  for p in b.peers:
    pending.add(b.addBlockEvent(p.id, cid))
    asyncCheck b.network.sendWantList(p.id, cid)

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
    return

  let blockPeer = b.session[0] # TODO: this should be a heapqueu
  # get the block from the best peer
  await b.network.sendWantList(
    blockPeer.id,
    cid,
    wantType = WantType.wantBlock)

  proc sendWants(info: BitswapInfo) {.async.} =
    if cid notin info.sentHaves:
      await b.network.sendWantList(info.id, cid, wantType = WantType.wantHave)

  checkFutures(
    await allFinished(b.session[1..b.session.high].map(sendWants)))

method getBlock*(b: Bitswap, cid: Cid): Future[bt.Block] =
  discard

method hasBlock*(b: Bitswap, cid: Cid): bool =
  discard

proc setupPeer(b: Bitswap, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  if peer notin b.peers:
    b.peers.add(BitswapInfo(
      id: peer
    ))

proc dropPeer(b: Bitswap, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  # check if there are any pending wants
  # or blocks and cancel them
  if peer in b.waitList:
    let waiting = b.waitList[peer]
    for f in toSeq(waiting.values):
      if not f.finished:
        f.cancel()

  # drop the peer from the peers table
  b.peers.keepItIf( it.id != peer )

proc new*(T: type Bitswap, store: BlockStore, network: BitswapNetwork): T =

  proc onBlocks(blocks: seq[Block]) =
    discard

  store.addChangeHandler(onBlocks)

  let waitList = initTable[Table[PeerID, Table[Cid, Future[void]]]]
  let b = Bitswap(
    store: store,
    network: network,
    waitList: waitList
    )

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      b.setupPeer(peerId)
    else:
      b.dropPeer(peerId)

  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockPresenceHandler(peer: PeerID, precense: seq[BlockPresence]) {.gcsafe.} =
    for b in precense:
      let cid = Cid.init(b.cid)
      var info = b.getInfo(peer)

      for list in b.wantList:
        if not isNil(info):
          # notify listeners of new want or block
          if cid in info.waitList:
            var list = info.waitList[cid]
            info.waitList[cid].complete(peer)

          if cid notin info.peerHave:
            if b.type == BlockPresenceType.presenceHave:
              info.peerHave.add(cid)

  return b
