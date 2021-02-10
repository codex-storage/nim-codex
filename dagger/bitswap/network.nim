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

import pkg/chronicles
import pkg/chronos

import pkg/libp2p

import ../blocktype as bt
import ./protobuf/bitswap as pb
import ./networkpeer

export pb, networkpeer

const Codec* = "/ipfs/bitswap/1.2.0"

type
  WantListHandler* = proc(peer: PeerID, wantList: WantList) {.gcsafe.}
  BlocksHandler* = proc(peer: PeerID, blocks: seq[bt.Block]) {.gcsafe.}
  BlockPresenceHandler* = proc(peer: PeerID, precense: seq[BlockPresence]) {.gcsafe.}

  BitswapNetwork* = ref object of LPProtocol
    peers*: Table[PeerID, NetworkPeer]
    switch: Switch
    onWantList*: WantListHandler
    onBlocks*: BlocksHandler
    onBlockPresence*: BlockPresenceHandler
    getConn: ConnProvider

proc handleWantList(
  b: BitswapNetwork,
  peer: NetworkPeer,
  list: WantList) =
  ## Handle incoming want list
  ##

  if isNil(b.onWantList):
    return

  b.onWantList(peer.id, list)

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

  let wantList = makeWantList(
    cids,
    priority,
    cancel,
    wantType,
    full,
    sendDontHave)
  asyncCheck b.peers[id].send(Message(wantlist: wantList))

proc handleBlocks(
  b: BitswapNetwork,
  peer: NetworkPeer,
  blocks: seq[auto]) =
  ## Handle incoming blocks
  ##

  if isNil(b.onBlocks):
    return

  var blks: seq[bt.Block]
  for blk in blocks:
    when blk is pb.Block:
      blks.add(bt.Block.new(Cid.init(blk.prefix).get(), blk.data))
    elif blk is seq[byte]:
      blks.add(bt.Block.new(Cid.init(blk).get(), blk))
    else:
      error("Invalid block type")

  b.onBlocks(peer.id, blks)

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

  asyncCheck b.peers[id].send(pb.Message(payload: makeBlocks(blocks)))

proc handleBlockPresence(
  b: BitswapNetwork,
  peer: NetworkPeer,
  presence: seq[BlockPresence]) =
  ## Handle block presence
  ##

  if isNil(b.onBlockPresence):
    return

  b.onBlockPresence(peer.id, presence)


proc broadcastBlockPresence*(
  b: BitswapNetwork,
  id: PeerID,
  presence: seq[BlockPresence]) =
  ## Send presence to remote
  ##

  if id in b.peers:
    asyncCheck b.peers[id].send(Message(blockPresences: presence))

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
  onWantList: WantListHandler = nil,
  onBlocks: BlocksHandler = nil,
  onBlockPresence: BlockPresenceHandler = nil,
  connProvider: ConnProvider = nil): T =
  ## Create a new BitswapNetwork instance
  ##

  let b = BitswapNetwork(
    switch: switch,
    onWantList: onWantList,
    onBlocks: onBlocks,
    onBlockPresence: onBlockPresence,
    getConn: connProvider)

  b.init()

  return b
