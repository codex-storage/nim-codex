## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/hashes
import std/sequtils

import message

import ../../blocktype

export Message, protobufEncode, protobufDecode
export Wantlist, WantType, WantListEntry
export BlockDelivery, BlockPresenceType, BlockPresence
export AccountMessage, StateChannelUpdate

proc hash*(e: WantListEntry): Hash =
  hash(e.address)

proc contains*(a: openArray[WantListEntry], b: BlockAddress): bool =
  ## Convenience method to check for peer precense
  ##

  a.anyIt(it.address == b)

proc `==`*(a: WantListEntry, b: BlockAddress): bool =
  return a.address == b

proc `<`*(a, b: WantListEntry): bool =
  a.priority < b.priority

proc `==`*(a: BlockPresence, b: BlockAddress): bool =
  return a.address == b

proc contains*(a: openArray[BlockPresence], b: BlockAddress): bool =
  ## Convenience method to check for peer precense
  ##

  a.anyIt(it.address == b)
