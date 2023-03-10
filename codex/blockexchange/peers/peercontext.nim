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

import pkg/chronicles
import pkg/libp2p
import pkg/chronos
import pkg/nitro
import pkg/questionable

import ../protobuf/blockexc
import ../protobuf/payments
import ../protobuf/presence

export payments, nitro

logScope:
  topics = "codex peercontext"

type
  BlockExcPeerCtx* = ref object of RootObj
    id*: PeerId
    blocks*: Table[Cid, Presence]     # remote peer have list including price
    peerWants*: seq[Entry]            # remote peers want lists
    exchanged*: int                   # times peer has exchanged with us
    lastExchange*: Moment             # last time peer has exchanged with us
    account*: ?Account                # ethereum account of this peer
    paymentChannel*: ?ChannelId       # payment channel id

proc peerHave*(self: BlockExcPeerCtx): seq[Cid] =
  toSeq(self.blocks.keys)

proc contains*(self: BlockExcPeerCtx, cid: Cid): bool =
  cid in self.blocks

func setPresence*(self: BlockExcPeerCtx, presence: Presence) =
  self.blocks[presence.cid] = presence

func cleanPresence*(self: BlockExcPeerCtx, cids: seq[Cid]) =
  for cid in cids:
    self.blocks.del(cid)

func cleanPresence*(self: BlockExcPeerCtx, cid: Cid) =
  self.cleanPresence(@[cid])

func price*(self: BlockExcPeerCtx, cids: seq[Cid]): UInt256 =
  var price = 0.u256
  for cid in cids:
    self.blocks.withValue(cid, precense):
      price += precense[].price

  trace "Blocks price", price
  price
