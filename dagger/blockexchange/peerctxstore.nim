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

import pkg/chronos
import pkg/libp2p

import ./peercontext
import ./protobuf/blockexc

type
  PeerCtxStore = ref object of RootObj
    peers: Table[PeerID, BlockExcPeerCtx]

iterator items*(self: PeerCtxStore): BlockExcPeerCtx =
  for p in peers.values:
    yield p

proc add*(self: PeerCtxStore, peer: BlockExcPeerCtx) =
  self.peers.add(peer.id, peer)

proc del*(self: PeerCtxStore, peer: BlockExcPeerCtx) =
   self.peers.del(peer.id)

proc peersHave*(self: PeerCtxStore, cid: Cid): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt( it.peerHave.anyIt( it == cid ) )

proc peersWant*(self: PeerCtxStore, cid: Cid): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt( it.peerWants.anyIt( it.cid == cid ) )

proc selectCheapest*(self: PeerCtxStore, cid: Cid): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt(
    toSeq(it.peerPrices).anyIt( it.cid == cid )
  ).sort()

proc new*(T: type PeerCtxStore): PeerCtxStore =
  T(peers: initTable[PeerID, PeerCtxStore])
