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
import pkg/libp2p/switch
import pkg/libp2p/stream/connection
import pkg/libp2p/protocols/protocol

import ../blocktype as bt
import ./bitswappeer
import ./protobuf/bitswap

const Codec = "/ipfs/bitswap/1.2.0"

type
  Bitswap* = ref object of LPProtocol
    peers: Table[PeerID, BitSwapPeer]
    switch: Switch

proc getOrCreatePeer(b: Bitswap, peer: PeerID): BitSwapPeer =
  ## Creates or retrieves a Bitswap Peer
  ##

  if peer in b.peers:
    return b.peers[peer]

  proc getConn(): Future[Connection] =
    b.switch.dial(peer, Codec)

  # create new pubsub peer
  let bitSwapPeer = BitSwapPeer.new(peer, getConn)
  debug "created new bitswap peer", peer

  b.peers[peer] = bitSwapPeer
  return bitSwapPeer

proc setupPeer(b: Bitswap, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  discard b.getOrCreatePeer(peer)

proc dropPeer(b: Bitswap, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  b.peers.del(peer)

proc getBlock(b: Bitswap, cid: Cid): Future[bt.Block] {.async.} =
  ## Retrieve a given CID from the network
  ##

  discard

method init*(b: Bitswap) =
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

proc new*(t: type Bitswap, switch: Switch): Bitswap =
  let b = Bitswap(switch: switch)
  b.init()
