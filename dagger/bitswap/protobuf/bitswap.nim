## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import pkg/protobuf_serialization
import pkg/libp2p

import_proto3 "message.proto"

export Message
export Wantlist, WantType, Entry
export Block, BlockPresenceType, BlockPresence

proc cid*(e: Entry): Cid {.inline.} =
  ## Helper to convert raw bytes to Cid
  ##

  Cid.init(e.`block`).get()

proc contains*(a: openarray[Entry], b: Cid): bool {.inline.} =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.cid == b ).len > 0

proc `==`*(a: Entry, cid: Cid): bool {.inline.} =
  return a.cid == cid

proc cid*(e: BlockPresence): Cid {.inline.} =
  ## Helper to convert raw bytes to Cid
  ##

  Cid.init(e.cid).get()

proc `==`*(a: BlockPresence, cid: Cid): bool {.inline.} =
  return cid(a) == cid

proc contains*(a: openarray[BlockPresence], b: Cid): bool {.inline.} =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( cid(it) == b ).len > 0
