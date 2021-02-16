## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables

import pkg/chronicles
import pkg/chronos

import pkg/libp2p

import ../blocktype as bt
import ./protobuf/bitswap as pb
import ./networkpeer

export pb, networkpeer

logScope:
  topics = "dagger bitswap network"

const Codec* = "/ipfs/bitswap/1.2.0"

type
  WantListHandler* = proc(peer: PeerID, wantList: WantList) {.gcsafe.}
  BlocksHandler* = proc(peer: PeerID, blocks: seq[bt.Block]) {.gcsafe.}
  BlockPresenceHandler* = proc(peer: PeerID, precense: seq[BlockPresence]) {.gcsafe.}

  BitswapHandlers* = object
    onWantList*: WantListHandler
    onBlocks*: BlocksHandler
    onPresence*: BlockPresenceHandler

  WantListBroadcaster* = proc(
    id: PeerID,
    cids: seq[Cid],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.wantHave,
    full: bool = false,
    sendDontHave: bool = false) {.gcsafe.}

  BlocksBroadcaster* = proc(peer: PeerID, presence: seq[bt.Block]) {.gcsafe.}
  PresenceBroadcaster* = proc(peer: PeerID, presence: seq[BlockPresence]) {.gcsafe.}

  BitswapRequest* = object
    sendWantList*: WantListBroadcaster
    sendBlocks*: BlocksBroadcaster
    sendPresence*: PresenceBroadcaster

  BitswapNetwork* = ref object of LPProtocol
    peers*: Table[PeerID, NetworkPeer]
    switch*: Switch
    handlers*: BitswapHandlers
    request*: BitswapRequest
    getConn: ConnProvider

proc handleWantList(
  b: BitswapNetwork,
  peer: NetworkPeer,
  list: WantList) =
  ## Handle incoming want list
  ##

  if isNil(b.handlers.onWantList):
    return

  trace "Handling want list for peer", peer = peer.id
  b.handlers.onWantList(peer.id, list)

# TODO: make into a template
proc makeWantList*(
  cids: seq[Cid],
  priority: int = 0,
  cancel: bool = false,
  wantType: WantType = WantType.wantHave,
  full: bool = false,
  sendDontHave: bool = false): WantList =
  var entries: seq[Entry]
  for cid in cids:
    entries.add(Entry(
      `block`: cid.data.buffer,
      priority: priority.int32,
      cancel: cancel,
      wantType: wantType,
      sendDontHave: sendDontHave))

  WantList(entries: entries, full: full)

proc broadcastWantList*(
  b: BitswapNetwork,
  id: PeerID,
  cids: seq[Cid],
  priority: int32 = 0,
  cancel: bool = false,
  wantType: WantType = WantType.wantHave,
  full: bool = false,
  sendDontHave: bool = false) =
  ## send a want message to peer
  ##

  if id notin b.peers:
    return

  trace "Sending want list to peer", peer = id, `type` = $wantType, len = cids.len

  let wantList = makeWantList(
    cids,
    priority,
    cancel,
    wantType,
    full,
    sendDontHave)
  asyncSpawn b.peers[id].send(Message(wantlist: wantList))

proc handleBlocks(
  b: BitswapNetwork,
  peer: NetworkPeer,
  blocks: seq[auto]) =
  ## Handle incoming blocks
  ##

  if isNil(b.handlers.onBlocks):
    return

  trace "Handling blocks for peer", peer = peer.id

  var blks: seq[bt.Block]
  for blk in blocks:
    when blk is pb.Block:
      blks.add(bt.Block.new(Cid.init(blk.prefix).get(), blk.data))
    elif blk is seq[byte]:
      blks.add(bt.Block.new(Cid.init(blk).get(), blk))
    else:
      error("Invalid block type")

  b.handlers.onBlocks(peer.id, blks)

template makeBlocks*(
  blocks: seq[bt.Block]):
  seq[pb.Block] =
  var blks: seq[pb.Block]
  for blk in blocks:
    # for now only send bitswap `1.1.0`
    blks.add(pb.Block(
      prefix: blk.cid.data.buffer,
      data: blk.data
    ))

  blks

proc broadcastBlocks*(
  b: BitswapNetwork,
  id: PeerID,
  blocks: seq[bt.Block]) =
  ## Send blocks to remote
  ##

  if id notin b.peers:
    return

  trace "Sending blocks to peer", peer = id, len = blocks.len
  asyncSpawn b.peers[id].send(pb.Message(payload: makeBlocks(blocks)))

proc handleBlockPresence(
  b: BitswapNetwork,
  peer: NetworkPeer,
  presence: seq[BlockPresence]) =
  ## Handle block presence
  ##

  if isNil(b.handlers.onPresence):
    return

  trace "Handling block presence for peer", peer = peer.id
  b.handlers.onPresence(peer.id, presence)

proc broadcastBlockPresence*(
  b: BitswapNetwork,
  id: PeerID,
  presence: seq[BlockPresence]) =
  ## Send presence to remote
  ##

  if id notin b.peers:
    return

  trace "Sending presence to peer", peer = id
  asyncSpawn b.peers[id].send(Message(blockPresences: presence))

proc rpcHandler(b: BitswapNetwork, peer: NetworkPeer, msg: Message) {.async.} =
  try:
    if msg.wantlist.entries.len > 0:
      b.handleWantList(peer, msg.wantlist)

    if msg.blocks.len > 0:
      b.handleBlocks(peer, msg.blocks)

    if msg.payload.len > 0:
      b.handleBlocks(peer, msg.payload)

    if msg.blockPresences.len > 0:
      b.handleBlockPresence(peer, msg.blockPresences)

  except CatchableError as exc:
    trace "Exception in bitswap rpc handler", exc = exc.msg

proc getOrCreatePeer(b: BitswapNetwork, peer: PeerID): NetworkPeer =
  ## Creates or retrieves a BitswapNetwork Peer
  ##

  if peer in b.peers:
    return b.peers[peer]

  var getConn = proc(): Future[Connection] {.async.} =
    try:
      return await b.switch.dial(peer, Codec)
    except CatchableError as exc:
      trace "unable to connect to bitswap peer", exc = exc.msg

  if not isNil(b.getConn):
    getConn = b.getConn

  let rpcHandler = proc (p: NetworkPeer, msg: Message): Future[void] =
    b.rpcHandler(p, msg)

  # create new pubsub peer
  let bitSwapPeer = NetworkPeer.new(peer, getConn, rpcHandler)
  debug "created new bitswap peer", peer

  b.peers[peer] = bitSwapPeer

  return bitSwapPeer

proc setupPeer*(b: BitswapNetwork, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  discard b.getOrCreatePeer(peer)

proc dropPeer*(b: BitswapNetwork, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  b.peers.del(peer)

method init*(b: BitswapNetwork) =
  ## Perform protocol initialization
  ##

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      b.setupPeer(peerId)
    else:
      b.dropPeer(peerId)

  b.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  b.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let peerId = conn.peerInfo.peerId
    let bitswapPeer = b.getOrCreatePeer(peerId)
    await bitswapPeer.readLoop(conn)  # attach read loop

  b.handler = handle
  b.codec = Codec

proc new*(
  T: type BitswapNetwork,
  switch: Switch,
  connProvider: ConnProvider = nil): T =
  ## Create a new BitswapNetwork instance
  ##

  let b = BitswapNetwork(
    switch: switch,
    getConn: connProvider)

  proc sendWantList(
    id: PeerID,
    cids: seq[Cid],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.wantHave,
    full: bool = false,
    sendDontHave: bool = false) {.gcsafe.} =
    b.broadcastWantList(
      id, cids, priority, cancel,
      wantType, full, sendDontHave)

  proc sendBlocks(id: PeerID, blocks: seq[bt.Block]) {.gcsafe.} =
    b.broadcastBlocks(id, blocks)

  proc sendPresence(id: PeerID, presence: seq[BlockPresence]) {.gcsafe.} =
    b.broadcastBlockPresence(id, presence)

  b.request = BitswapRequest(
    sendWantList: sendWantList,
    sendBlocks: sendBlocks,
    sendPresence: sendPresence,
  )

  b.init()
  return b
