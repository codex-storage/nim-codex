## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/chronos
import pkg/libp2p

import ../blocktype

export blocktype, libp2p

type
  ChangeType* {.pure.} = enum
    Added, Removed

  BlockStoreChangeEvt* = object
    cids*: seq[Cid]
    kind*: ChangeType

  BlocksChangeHandler* = proc(evt: BlockStoreChangeEvt) {.gcsafe, closure.}

  BlockStore* = ref object of RootObj
    changeHandlers: array[ChangeType, seq[BlocksChangeHandler]]

proc addChangeHandler*(
  s: BlockStore,
  handler: BlocksChangeHandler,
  changeType: ChangeType) =
  s.changeHandlers[changeType].add(handler)

proc removeChangeHandler*(
  s: BlockStore,
  handler: BlocksChangeHandler,
  changeType: ChangeType) =
  s.changeHandlers[changeType].keepItIf( it != handler )

proc triggerChange(
  s: BlockStore,
  changeType: ChangeType,
  cids: seq[Cid]) =
  let evt = BlockStoreChangeEvt(
    kind: changeType,
    cids: cids,
  )

  for handler in s.changeHandlers[changeType]:
    handler(evt)

{.push locks:"unknown".}

method getBlocks*(b: BlockStore, cid: seq[Cid]): Future[seq[Block]] {.base.} =
  ## Get a block from the stores
  ##

  doAssert(false, "Not implemented!")

method hasBlock*(s: BlockStore, cid: Cid): bool {.base.} =
  ## Check if the block exists in the blockstore
  ##

  return false

method putBlocks*(s: BlockStore, blocks: seq[Block]) {.base.} =
  ## Put a block to the blockstore
  ##

  s.triggerChange(ChangeType.Added, blocks.mapIt( it.cid ))

method delBlocks*(s: BlockStore, blocks: seq[Cid]) {.base.} =
  ## Delete a block/s from the block store
  ##

  s.triggerChange(ChangeType.Removed, blocks)

{.pop.}

proc contains*(s: BlockStore, blk: Cid): bool =
  s.hasBlock(blk)
