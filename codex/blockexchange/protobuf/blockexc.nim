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
import pkg/stew/endians2

import message

import ../../blocktype

export Message, protobufEncode, protobufDecode
export Wantlist, WantType, Entry
export BlockDelivery, BlockPresenceType, BlockPresence
export AccountMessage, StateChannelUpdate

proc hash*(e: Entry): Hash =
  # hash(e.`block`)
  if e.address.leaf:
    let data = e.address.treeCid.data.buffer & @(e.address.index.uint64.toBytesBE)
    hash(data)
  else:
    hash(e.address.cid.data.buffer)
  

# proc cid*(e: Entry): Cid  =
#   ## Helper to convert raw bytes to Cid
#   ##

#   Cid.init(e.`block`).get()

proc contains*(a: openArray[Entry], b: BlockAddress): bool =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.address == b ).len > 0

proc `==`*(a: Entry, b: BlockAddress): bool =
  return a.address == b

proc `<`*(a, b: Entry): bool =
  a.priority < b.priority

# proc cid*(e: BlockPresence): Cid =
#   ## Helper to convert raw bytes to Cid
#   ##

#   Cid.init(e.cid).get()

proc `==`*(a: BlockPresence, b: BlockAddress): bool =
  return a.address == b

proc contains*(a: openArray[BlockPresence], b: BlockAddress): bool =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.address == b ).len > 0
