## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/sequtils

import pkg/chronos
import pkg/libp2p
import pkg/questionable

import ../blocktype

export blocktype, libp2p

type
  BlockStore* = ref object of RootObj

{.push locks:"unknown".}

method getBlock*(
  b: BlockStore,
  cid: Cid): Future[?Block] {.base.} =
  ## Get a block from the stores
  ##

  doAssert(false, "Not implemented!")

method putBlock*(
  s: BlockStore,
  blk: Block): Future[void] {.base.} =
  ## Put a block to the blockstore
  ##

  doAssert(false, "Not implemented!")

method delBlock*(
  s: BlockStore,
  cid: Cid): Future[void] {.base.} =
  ## Delete a block/s from the block store
  ##

  doAssert(false, "Not implemented!")

{.pop.}

method hasBlock*(s: BlockStore, cid: Cid): bool {.base.} =
  ## Check if the block exists in the blockstore
  ##

  return false

proc contains*(s: BlockStore, blk: Cid): bool =
  s.hasBlock(blk)
