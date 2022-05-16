## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sugar
import std/sequtils
import std/tables
import std/algorithm

import pkg/upraises

push: {.upraises: [].}

import pkg/chronos
import pkg/libp2p

import ../protobuf/blockexc

import ./peercontext

export peercontext

type
  PeerCtxStore* = ref object of RootObj
    peers*: Table[PeerID, BlockExcPeerCtx]

iterator items*(self: PeerCtxStore): BlockExcPeerCtx =
  for p in self.peers.values:
    yield p

func contains*(self: PeerCtxStore, peerId: PeerID): bool =
  peerId in self.peers

func add*(self: PeerCtxStore, peer: BlockExcPeerCtx) =
  self.peers[peer.id] = peer

func remove*(self: PeerCtxStore, peerId: PeerID) =
   self.peers.del(peerId)

func get*(self: PeerCtxStore, peerId: PeerID): BlockExcPeerCtx =
  self.peers.withValue(peerId, peer):
    return peer[]

func len*(self: PeerCtxStore): int = self.peers.len

func peersHave*(self: PeerCtxStore, cid: Cid): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt( it.peerHave.anyIt( it == cid ) )

func peersWant*(self: PeerCtxStore, cid: Cid): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt( it.peerWants.anyIt( it.cid == cid ) )

func selectCheapest*(self: PeerCtxStore, cid: Cid): seq[BlockExcPeerCtx] =
  var
    peers = self.peersHave(cid)

  func cmp(a, b: BlockExcPeerCtx): int =
    # Can't do (a - b) without cast[int](a - b)
    if a.peerPrices.getOrDefault(cid, 0.u256) ==
      b.peerPrices.getOrDefault(cid, 0.u256):
      0
    elif a.peerPrices.getOrDefault(cid, 0.u256) >
      b.peerPrices.getOrDefault(cid, 0.u256):
      1
    else:
      -1

  peers.sort(cmp)
  return peers

proc new*(T: type PeerCtxStore): PeerCtxStore =
  T(peers: initTable[PeerID, BlockExcPeerCtx]())
