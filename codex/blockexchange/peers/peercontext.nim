## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/tables
import std/sets

import pkg/libp2p
import pkg/chronos
import pkg/nitro
import pkg/questionable

import ../protobuf/blockexc
import ../protobuf/payments
import ../protobuf/presence

import ../../blocktype
import ../../logutils

export payments, nitro

type BlockExcPeerCtx* = ref object of RootObj
  id*: PeerId
  blocks*: Table[BlockAddress, Presence] # remote peer have list including price
  wantedBlocks*: HashSet[BlockAddress] # blocks that the peer wants
  exchanged*: int # times peer has exchanged with us
  lastExchange*: Moment # last time peer has exchanged with us
  lastRefresh*: Moment # last time we refreshed our knowledge of the blocks this peer has
  account*: ?Account # ethereum account of this peer
  paymentChannel*: ?ChannelId # payment channel id
  blocksInFlight*: HashSet[BlockAddress] # blocks in flight towards peer

proc isKnowledgeStale*(self: BlockExcPeerCtx): bool =
  self.lastRefresh + 5.minutes < Moment.now()

proc isInFlight*(self: BlockExcPeerCtx, address: BlockAddress): bool =
  address in self.blocksInFlight

proc addInFlight*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksInFlight.incl(address)

proc removeInFlight*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksInFlight.excl(address)

proc refreshed*(self: BlockExcPeerCtx) =
  self.lastRefresh = Moment.now()

proc peerHave*(self: BlockExcPeerCtx): HashSet[BlockAddress] =
  # XXX: this is ugly an inefficient, but since those will typically
  #  be used in "joins", it's better to pay the price here and have
  #  a linear join than to not do it and have a quadratic join.
  toHashSet(self.blocks.keys.toSeq)

proc contains*(self: BlockExcPeerCtx, address: BlockAddress): bool =
  address in self.blocks

func setPresence*(self: BlockExcPeerCtx, presence: Presence) =
  self.blocks[presence.address] = presence

func cleanPresence*(self: BlockExcPeerCtx, addresses: seq[BlockAddress]) =
  for a in addresses:
    self.blocks.del(a)

func cleanPresence*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.cleanPresence(@[address])

func price*(self: BlockExcPeerCtx, addresses: seq[BlockAddress]): UInt256 =
  var price = 0.u256
  for a in addresses:
    self.blocks.withValue(a, precense):
      price += precense[].price

  price
