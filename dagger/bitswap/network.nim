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

const Codec = "/ipfs/bitswap/1.2.0"

type
  WantListHandler* = proc(peer: PeerID, wantList: WantList) {.gcsafe.}
  BlocksHandler* = proc(peer: PeerID, blocks: seq[byte]) {.gcsafe.}
  BlockPresenceHandler* = proc(peer: PeerID, precense: seq[BlockPresence]) {.gcsafe.}

  BitswapNetwork* = ref object of LPProtocol
    peers*: Table[PeerID, NetworkPeer]
    switch: Switch
    onWantList*: WantListHandler
    onBlocks*: BlocksHandler
    onBlockPresence*: BlockPresenceHandler

proc handleWantList(
  b: BitswapNetwork,
  peer: NetworkPeer,
  list: WantList) =
  discard

proc sendWantList*(
  b: BitswapNetwork,
  id: PeerID,
  cids: seq[Cid],
  priority: int32 = 0,
  cancel: bool = false,
  wantType: WantType = WantType.wantHave,
  full: bool = false,
  sendDontHave: bool = false) {.async.} =
  ## send a want message to peer
  ##

  if id notin b.peers:
    return

  var entries: seq[Entry]
  for cid in cids:
    entries.add(Entry(
      `block`: cid.data.buffer,
      priority: priority,
      cancel: cancel,
      wantType: wantType,
      sendDontHave: sendDontHave))

  let wantList = WantList(entries: entries, full: full)
  await b.peers[id].send(Message(wantlist: wantList))

proc handleBlocks(
  b: BitswapNetwork,
  peer: NetworkPeer,
  blocks: seq[auto]) =
  discard

proc sendBlocks*(
  b: BitswapNetwork,
  peer: PeerID,
  blocks: seq[auto]) =
  discard

proc handlePayload(
  b: BitswapNetwork,
  peer: NetworkPeer,
  payload: seq[pb.Block]) =
  discard

proc sendPayload*(
  b: BitswapNetwork,
  peer: PeerID,
  payload: seq[pb.Block]) =
  discard

proc handleBlockPresense(
  b: BitswapNetwork,
  peer: NetworkPeer,
  presence: seq[BlockPresence]) =
  discard

proc sendBlockPresense*(
  b: BitswapNetwork,
  peer: PeerID,
  presence: seq[BlockPresence]) =
  discard

proc rpcHandler*(b: BitswapNetwork, peer: NetworkPeer, msg: Message) {.async.} =
  try:
    if msg.wantlist.entries.len > 0:
      b.handleWantList(peer, msg.wantlist)

    if msg.blocks.len > 0:
      b.handleBlocks(peer, msg.blocks)

    if msg.payload.len > 0:
      b.handlePayload(peer, msg.payload)

    if msg.blockPresences.len > 0:
      b.handleBlockPresense(peer, msg.blockPresences)

  except CatchableError as exc:
    trace "Exception in bitswap rpc handler", exc = exc.msg

proc getOrCreatePeer(b: BitswapNetwork, peer: PeerID): NetworkPeer =
  ## Creates or retrieves a BitswapNetwork Peer
  ##

  if peer in b.peers:
    return b.peers[peer]

  proc getConn(): Future[Connection] =
    b.switch.dial(peer, Codec)

  proc rpcHandler(p: NetworkPeer, msg: Message): Future[void] =
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
  onBlockPresence: BlockPresenceHandler = nil): T =
  let b = BitswapNetwork(
    switch: switch,
    onWantList: onWantList,
    onBlocks: onBlocks,
    onBlockPresence: onBlockPresence)

  b.init()

  return b
