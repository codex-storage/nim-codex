## Nim-Codex
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
import pkg/libp2p/utils/semaphore
import pkg/questionable
import pkg/questionable/results

import ../../blocktype as bt
import ../protobuf/blockexc as pb
import ../protobuf/payments

import ./networkpeer

export network, payments

logScope:
  topics = "codex blockexcnetwork"

const
  Codec* = "/codex/blockexc/1.0.0"
  MaxInflight* = 100

type
  WantListHandler* = proc(peer: PeerID, wantList: WantList): Future[void] {.gcsafe.}
  BlocksHandler* = proc(peer: PeerID, blocks: seq[bt.Block]): Future[void] {.gcsafe.}
  BlockPresenceHandler* = proc(peer: PeerID, precense: seq[BlockPresence]): Future[void] {.gcsafe.}
  AccountHandler* = proc(peer: PeerID, account: Account): Future[void] {.gcsafe.}
  PaymentHandler* = proc(peer: PeerID, payment: SignedState): Future[void] {.gcsafe.}
  WantListSender* = proc(
    id: PeerID,
    cids: seq[Cid],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false): Future[void] {.gcsafe.}

  BlockExcHandlers* = object
    onWantList*: WantListHandler
    onBlocks*: BlocksHandler
    onPresence*: BlockPresenceHandler
    onAccount*: AccountHandler
    onPayment*: PaymentHandler

  BlocksSender* = proc(peer: PeerID, presence: seq[bt.Block]): Future[void] {.gcsafe.}
  PresenceSender* = proc(peer: PeerID, presence: seq[BlockPresence]): Future[void] {.gcsafe.}
  AccountSender* = proc(peer: PeerID, account: Account): Future[void] {.gcsafe.}
  PaymentSender* = proc(peer: PeerID, payment: SignedState): Future[void] {.gcsafe.}

  BlockExcRequest* = object
    sendWantList*: WantListSender
    sendBlocks*: BlocksSender
    sendPresence*: PresenceSender
    sendAccount*: AccountSender
    sendPayment*: PaymentSender

  BlockExcNetwork* = ref object of LPProtocol
    peers*: Table[PeerID, NetworkPeer]
    switch*: Switch
    handlers*: BlockExcHandlers
    request*: BlockExcRequest
    getConn: ConnProvider
    inflightSema: AsyncSemaphore

proc send*(b: BlockExcNetwork, id: PeerId, msg: pb.Message) {.async.} =
  ## Send message to peer
  ##

  b.peers.withValue(id, peer):
    try:
      await b.inflightSema.acquire()
      trace "Sending message to peer", peer = id
      await peer[].send(msg)
    finally:
      b.inflightSema.release()
  do:
    trace "Unable to send, peer not found", peerId = id

proc handleWantList(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  list: WantList) {.async.} =
  ## Handle incoming want list
  ##

  if not b.handlers.onWantList.isNil:
    trace "Handling want list for peer", peer = peer.id, items = list.entries.len
    await b.handlers.onWantList(peer.id, list)

# TODO: make into a template
proc makeWantList*(
  cids: seq[Cid],
  priority: int = 0,
  cancel: bool = false,
  wantType: WantType = WantType.WantHave,
  full: bool = false,
  sendDontHave: bool = false): WantList =
  WantList(
    entries: cids.mapIt(
      Entry(
        `block`: it.data.buffer,
        priority: priority.int32,
        cancel: cancel,
        wantType: wantType,
        sendDontHave: sendDontHave) ),
    full: full)

proc sendWantList*(
  b: BlockExcNetwork,
  id: PeerID,
  cids: seq[Cid],
  priority: int32 = 0,
  cancel: bool = false,
  wantType: WantType = WantType.WantHave,
  full: bool = false,
  sendDontHave: bool = false): Future[void] =
  ## Send a want message to peer
  ##

  trace "Sending want list to peer", peer = id, `type` = $wantType, items = cids.len
  let msg = makeWantList(
        cids,
        priority,
        cancel,
        wantType,
        full,
        sendDontHave)

  b.send(id, Message(wantlist: msg))

proc handleBlocks(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  blocks: seq[pb.Block]) {.async.} =
  ## Handle incoming blocks
  ##

  if not b.handlers.onBlocks.isNil:
    trace "Handling blocks for peer", peer = peer.id, items = blocks.len

    var blks: seq[bt.Block]
    for blob in blocks:
      without cid =? Cid.init(blob.prefix):
        trace "Unable to initialize Cid from protobuf message"

      without blk =? bt.Block.new(cid, blob.data, verify = true):
        trace "Unable to initialize Block from data"

      blks.add(blk)

    await b.handlers.onBlocks(peer.id, blks)

template makeBlocks*(blocks: seq[bt.Block]): seq[pb.Block] =
  var blks: seq[pb.Block]
  for blk in blocks:
    blks.add(pb.Block(
      prefix: blk.cid.data.buffer,
      data: blk.data
    ))

  blks

proc sendBlocks*(
  b: BlockExcNetwork,
  id: PeerID,
  blocks: seq[bt.Block]): Future[void] =
  ## Send blocks to remote
  ##

  b.send(id, pb.Message(payload: makeBlocks(blocks)))

proc handleBlockPresence(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  presence: seq[BlockPresence]) {.async.} =
  ## Handle block presence
  ##

  if not b.handlers.onPresence.isNil:
    trace "Handling block presence for peer", peer = peer.id, items = presence.len
    await b.handlers.onPresence(peer.id, presence)

proc sendBlockPresence*(
  b: BlockExcNetwork,
  id: PeerID,
  presence: seq[BlockPresence]): Future[void] =
  ## Send presence to remote
  ##

  b.send(id, Message(blockPresences: @presence))

proc handleAccount(
  network: BlockExcNetwork,
  peer: NetworkPeer,
  account: Account) {.async.} =
  ## Handle account info
  ##

  if not network.handlers.onAccount.isNil:
    await network.handlers.onAccount(peer.id, account)

proc sendAccount*(
  b: BlockExcNetwork,
  id: PeerId,
  account: Account): Future[void] =
  ## Send account info to remote
  ##

  b.send(id, Message(account: AccountMessage.init(account)))

proc sendPayment*(
  b: BlockExcNetwork,
  id: PeerId,
  payment: SignedState): Future[void] =
  ## Send payment to remote
  ##

  b.send(id, Message(payment: StateChannelUpdate.init(payment)))

proc handlePayment(
  network: BlockExcNetwork,
  peer: NetworkPeer,
  payment: SignedState) {.async.} =
  ## Handle payment
  ##

  if not network.handlers.onPayment.isNil:
    await network.handlers.onPayment(peer.id, payment)

proc rpcHandler(b: BlockExcNetwork, peer: NetworkPeer, msg: Message) {.async.} =
  try:
    if msg.wantlist.entries.len > 0:
      asyncSpawn b.handleWantList(peer, msg.wantlist)

    if msg.payload.len > 0:
      asyncSpawn b.handleBlocks(peer, msg.payload)

    if msg.blockPresences.len > 0:
      asyncSpawn b.handleBlockPresence(peer, msg.blockPresences)

    if account =? Account.init(msg.account):
      asyncSpawn b.handleAccount(peer, account)

    if payment =? SignedState.init(msg.payment):
      asyncSpawn b.handlePayment(peer, payment)

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
      trace "Unable to connect to blockexc peer", exc = exc.msg

  if not isNil(b.getConn):
    getConn = b.getConn

  let rpcHandler = proc (p: NetworkPeer, msg: Message): Future[void] =
    b.rpcHandler(p, msg)

  # create new pubsub peer
  let blockExcPeer = NetworkPeer.new(peer, getConn, rpcHandler)
  debug "Created new blockexc peer", peer

  b.peers[peer] = blockExcPeer

  return blockExcPeer

proc setupPeer*(b: BlockExcNetwork, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  discard b.getOrCreatePeer(peer)

proc dialPeer*(b: BlockExcNetwork, peer: PeerRecord) {.async.} =
  await b.switch.connect(peer.peerId, peer.addresses.mapIt(it.address))

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
  connProvider: ConnProvider = nil,
  maxInflight = MaxInflight): T =
  ## Create a new BlockExcNetwork instance
  ##

  let
    self = BlockExcNetwork(
      switch: switch,
      getConn: connProvider,
      inflightSema: newAsyncSemaphore(maxInflight))

  proc sendWantList(
    id: PeerID,
    cids: seq[Cid],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false): Future[void] {.gcsafe.} =
    self.sendWantList(
      id, cids, priority, cancel,
      wantType, full, sendDontHave)

  proc sendBlocks(id: PeerID, blocks: seq[bt.Block]): Future[void] {.gcsafe.} =
    self.sendBlocks(id, blocks)

  proc sendPresence(id: PeerID, presence: seq[BlockPresence]): Future[void] {.gcsafe.} =
    self.sendBlockPresence(id, presence)

  proc sendAccount(id: PeerID, account: Account): Future[void] {.gcsafe.} =
    self.sendAccount(id, account)

  proc sendPayment(id: PeerID, payment: SignedState): Future[void] {.gcsafe.} =
    self.sendPayment(id, payment)

  self.request = BlockExcRequest(
    sendWantList: sendWantList,
    sendBlocks: sendBlocks,
    sendPresence: sendPresence,
    sendAccount: sendAccount,
    sendPayment: sendPayment)

  self.init()
  return self
