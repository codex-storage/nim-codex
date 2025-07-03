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
  lastRefresh*: Moment # last time we refreshed our knowledge of the blocks this peer has
  account*: ?Account # ethereum account of this peer
  paymentChannel*: ?ChannelId # payment channel id
  blocksSent*: HashSet[BlockAddress] # blocks sent to peer
  blocksRequested*: HashSet[BlockAddress] # pending block requests to this peer
  lastExchange*: Moment # last time peer has sent us a block
  activityTimeout*: Duration

proc isKnowledgeStale*(self: BlockExcPeerCtx): bool =
  self.lastRefresh + 5.minutes < Moment.now()

proc isBlockSent*(self: BlockExcPeerCtx, address: BlockAddress): bool =
  address in self.blocksSent

proc markBlockAsSent*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksSent.incl(address)

proc markBlockAsNotSent*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksSent.excl(address)

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

proc blockRequestScheduled*(self: BlockExcPeerCtx, address: BlockAddress) =
  ## Adds a block the set of blocks that have been requested to this peer
  ## (its request schedule).
  if self.blocksRequested.len == 0:
    self.lastExchange = Moment.now()
  self.blocksRequested.incl(address)

proc blockRequestCancelled*(self: BlockExcPeerCtx, address: BlockAddress) =
  ## Removes a block from the set of blocks that have been requested to this peer
  ## (its request schedule).
  self.blocksRequested.excl(address)

proc blockReceived*(self: BlockExcPeerCtx, address: BlockAddress): bool =
  let wasRequested = address in self.blocksRequested
  self.blocksRequested.excl(address)
  self.lastExchange = Moment.now()
  wasRequested

proc activityTimer*(
    self: BlockExcPeerCtx
): Future[void] {.async: (raises: [CancelledError]).} =
  ## This is called by the block exchange when a block is scheduled for this peer.
  ## If the peer sends no blocks for a while, it is considered inactive/uncooperative
  ## and the peer is dropped. Note that ANY block that the peer sends will reset this
  ## timer for all blocks.
  ##
  while true:
    let idleTime = Moment.now() - self.lastExchange
    if idleTime > self.activityTimeout:
      return

    await sleepAsync(self.activityTimeout - idleTime)
