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
import pkg/questionable
import pkg/questionable/results

import ../blocktype as bt
import ./protobuf/blockexc as pb
import ./protobuf/payments
import ./networkpeer

export networkpeer, payments

logScope:
  topics = "dagger blockexc network"

const Codec* = "/dagger/blockexc/1.0.0"

type
  WantListHandler* = proc(peer: PeerID, wantList: WantList): Future[void] {.gcsafe.}
  BlocksHandler* = proc(peer: PeerID, blocks: seq[bt.Block]): Future[void] {.gcsafe.}
  BlockPresenceHandler* = proc(peer: PeerID, precense: seq[BlockPresence]): Future[void] {.gcsafe.}
  AccountHandler* = proc(peer: PeerID, account: Account): Future[void] {.gcsafe.}
  PaymentHandler* = proc(peer: PeerID, payment: SignedState): Future[void] {.gcsafe.}

  BlockExcHandlers* = object
    onWantList*: WantListHandler
    onBlocks*: BlocksHandler
    onPresence*: BlockPresenceHandler
    onAccount*: AccountHandler
    onPayment*: PaymentHandler

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
  AccountBroadcaster* = proc(peer: PeerID, account: Account) {.gcsafe.}
  PaymentBroadcaster* = proc(peer: PeerID, payment: SignedState) {.gcsafe.}

  BlockExcRequest* = object
    sendWantList*: WantListBroadcaster
    sendBlocks*: BlocksBroadcaster
    sendPresence*: PresenceBroadcaster
    sendAccount*: AccountBroadcaster
    sendPayment*: PaymentBroadcaster

  BlockExcNetwork* = ref object of LPProtocol
    peers*: Table[PeerID, NetworkPeer]
    switch*: Switch
    handlers*: BlockExcHandlers
    request*: BlockExcRequest
    getConn: ConnProvider

proc handleWantList(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  list: WantList): Future[void] =
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
  b: BlockExcNetwork,
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

  let
    wantList = makeWantList(
      cids,
      priority,
      cancel,
      wantType,
      full,
      sendDontHave)
  b.peers.withValue(id, peer):
    peer[].broadcast(Message(wantlist: wantList))

proc handleBlocks(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  blocks: seq[pb.Block]): Future[void] =
  ## Handle incoming blocks
  ##

  if isNil(b.handlers.onBlocks):
    return

  trace "Handling blocks for peer", peer = peer.id

  var blks: seq[bt.Block]
  for blob in blocks:
    without cid =? Cid.init(blob.prefix):
      trace "Unable to initialize Cid from protobuf message"

    without blk =? bt.Block.new(cid, blob.data, verify = true):
      trace "Unable to initialize Block from data"

    blks.add(blk)

  b.handlers.onBlocks(peer.id, blks)

template makeBlocks*(blocks: seq[bt.Block]): seq[pb.Block] =
  var blks: seq[pb.Block]
  for blk in blocks:
    blks.add(pb.Block(
      prefix: blk.cid.data.buffer,
      data: blk.data
    ))

  blks

proc broadcastBlocks*(
  b: BlockExcNetwork,
  id: PeerID,
  blocks: seq[bt.Block]) =
  ## Send blocks to remote
  ##

  if id notin b.peers:
    return

  trace "Sending blocks to peer", peer = id, len = blocks.len
  b.peers.withValue(id, peer):
    peer[].broadcast(pb.Message(payload: makeBlocks(blocks)))

proc handleBlockPresence(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  presence: seq[BlockPresence]): Future[void] =
  ## Handle block presence
  ##

  if isNil(b.handlers.onPresence):
    return

  trace "Handling block presence for peer", peer = peer.id
  b.handlers.onPresence(peer.id, presence)

proc broadcastBlockPresence*(
  b: BlockExcNetwork,
  id: PeerID,
  presence: seq[BlockPresence]) =
  ## Send presence to remote
  ##

  if id notin b.peers:
    return

  trace "Sending presence to peer", peer = id
  b.peers.withValue(id, peer):
    peer[].broadcast(Message(blockPresences: @presence))

proc handleAccount(network: BlockExcNetwork,
                   peer: NetworkPeer,
                   account: Account): Future[void] =
  if network.handlers.onAccount.isNil:
    return
  network.handlers.onAccount(peer.id, account)

proc broadcastAccount*(network: BlockExcNetwork,
                       id: PeerId,
                       account: Account) =
  if id notin network.peers:
    return

  let message = Message(account: AccountMessage.init(account))
  network.peers.withValue(id, peer):
    peer[].broadcast(message)

proc broadcastPayment*(network: BlockExcNetwork,
                       id: PeerId,
                       payment: SignedState) =
  if id notin network.peers:
    return

  let message = Message(payment: StateChannelUpdate.init(payment))
  network.peers.withValue(id, peer):
    peer[].broadcast(message)

proc handlePayment(network: BlockExcNetwork,
                   peer: NetworkPeer,
                   payment: SignedState): Future[void] =
  if network.handlers.onPayment.isNil:
    return
  network.handlers.onPayment(peer.id, payment)

proc rpcHandler(b: BlockExcNetwork, peer: NetworkPeer, msg: Message) {.async.} =
  try:
    if msg.wantlist.entries.len > 0:
      await b.handleWantList(peer, msg.wantlist)

    if msg.payload.len > 0:
      await b.handleBlocks(peer, msg.payload)

    if msg.blockPresences.len > 0:
      await b.handleBlockPresence(peer, msg.blockPresences)

    if account =? Account.init(msg.account):
      await b.handleAccount(peer, account)

    if payment =? SignedState.init(msg.payment):
      await b.handlePayment(peer, payment)

  except CatchableError as exc:
    trace "Exception in blockexc rpc handler", exc = exc.msg

proc getOrCreatePeer(b: BlockExcNetwork, peer: PeerID): NetworkPeer =
  ## Creates or retrieves a BlockExcNetwork Peer
  ##

  if peer in b.peers:
    return b.peers.getOrDefault(peer, nil)

  var getConn = proc(): Future[Connection] {.async.} =
    try:
      return await b.switch.dial(peer, Codec)
    except CatchableError as exc:
      trace "unable to connect to blockexc peer", exc = exc.msg

  if not isNil(b.getConn):
    getConn = b.getConn

  let rpcHandler = proc (p: NetworkPeer, msg: Message): Future[void] =
    b.rpcHandler(p, msg)

  # create new pubsub peer
  let blockExcPeer = NetworkPeer.new(peer, getConn, rpcHandler)
  debug "created new blockexc peer", peer

  b.peers[peer] = blockExcPeer

  return blockExcPeer

proc setupPeer*(b: BlockExcNetwork, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  discard b.getOrCreatePeer(peer)

proc dialPeer*(b: BlockExcNetwork, peer: PeerRecord) {.async.} =
  try:
    await b.switch.connect(peer.peerId, peer.addresses.mapIt(it.address))
  except CatchableError as exc:
    debug "Failed to connect to peer", error=exc.msg

proc dropPeer*(b: BlockExcNetwork, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  b.peers.del(peer)

method init*(b: BlockExcNetwork) =
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
    let peerId = conn.peerId
    let blockexcPeer = b.getOrCreatePeer(peerId)
    await blockexcPeer.readLoop(conn)  # attach read loop

  b.handler = handle
  b.codec = Codec

proc new*(
  T: type BlockExcNetwork,
  switch: Switch,
  connProvider: ConnProvider = nil): T =
  ## Create a new BlockExcNetwork instance
  ##

  let b = BlockExcNetwork(
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

  proc sendAccount(id: PeerID, account: Account) =
    b.broadcastAccount(id, account)

  proc sendPayment(id: PeerID, payment: SignedState) =
    b.broadcastPayment(id, payment)

  b.request = BlockExcRequest(
    sendWantList: sendWantList,
    sendBlocks: sendBlocks,
    sendPresence: sendPresence,
    sendAccount: sendAccount,
    sendPayment: sendPayment)

  b.init()
  return b
