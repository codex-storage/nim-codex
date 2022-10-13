## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/hashes
import std/sequtils
import pkg/libp2p

import message

export Message, ProtobufEncode, ProtobufDecode
export Wantlist, WantType, Entry
export Block, BlockPresenceType, BlockPresence
export AccountMessage, StateChannelUpdate

proc hash*(e: Entry): Hash =
  hash(e.`block`)

proc cid*(e: Entry): Cid  =
  ## Helper to convert raw bytes to Cid
  ##

  Cid.init(e.`block`).get()

proc contains*(a: openArray[Entry], b: Cid): bool =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.cid == b ).len > 0

proc `==`*(a: Entry, cid: Cid): bool =
  return a.cid == cid

proc `<`*(a, b: Entry): bool =
  a.priority < b.priority

proc cid*(e: BlockPresence): Cid =
  ## Helper to convert raw bytes to Cid
  ##

  Cid.init(e.cid).get()

proc `==`*(a: BlockPresence, cid: Cid): bool =
  return cid(a) == cid

proc contains*(a: openArray[BlockPresence], b: Cid): bool =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( cid(it) == b ).len > 0
