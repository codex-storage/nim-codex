## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/tables

import pkg/libp2p

import ../../logutils

import ./peercontext
export peercontext

logScope:
  topics = "storage peerctxstore"

type PeerContextStore* = ref object of RootObj
  peers*: OrderedTable[PeerId, PeerContext]

iterator items*(self: PeerContextStore): PeerContext =
  for p in self.peers.values:
    yield p

proc contains*(a: openArray[PeerContext], b: PeerId): bool =
  ## Convenience method to check for peer precense
  ##

  a.anyIt(it.id == b)

func peerIds*(self: PeerContextStore): seq[PeerId] =
  toSeq(self.peers.keys)

func contains*(self: PeerContextStore, peerId: PeerId): bool =
  peerId in self.peers

func add*(self: PeerContextStore, peer: PeerContext) =
  self.peers[peer.id] = peer

func remove*(self: PeerContextStore, peerId: PeerId) =
  self.peers.del(peerId)

func get*(self: PeerContextStore, peerId: PeerId): PeerContext =
  self.peers.getOrDefault(peerId, nil)

func len*(self: PeerContextStore): int =
  self.peers.len

proc new*(T: type PeerContextStore): PeerContextStore =
  ## create new instance of a peer context store
  PeerContextStore(peers: initOrderedTable[PeerId, PeerContext]())
