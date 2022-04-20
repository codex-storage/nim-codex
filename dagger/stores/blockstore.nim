## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import pkg/chronos
import pkg/libp2p
import pkg/questionable/results

import ../blocktype

export blocktype, libp2p

type
  OnBlock* = proc(blk: Block): Future[void] {.upraises: [], gcsafe.}
  BlockStore* = ref object of RootObj

method getBlock*(
  b: BlockStore,
  cid: Cid): Future[?!Block] {.base.} =
  ## Get a block from the stores
  ##

  raiseAssert("Not implemented!")

method putBlock*(
  s: BlockStore,
  blk: Block): Future[bool] {.base.} =
  ## Put a block to the blockstore
  ##

  raiseAssert("Not implemented!")

method delBlock*(
  s: BlockStore,
  cid: Cid): Future[bool] {.base.} =
  ## Delete a block/s from the block store
  ##

  raiseAssert("Not implemented!")

method hasBlock*(s: BlockStore, cid: Cid): bool {.base.} =
  ## Check if the block exists in the blockstore
  ##

  return false

method listBlocks*(s: BlockStore, onBlock: OnBlock): Future[void] {.base.} =
  ## Get the list of blocks in the BlockStore. This is an intensive operation
  ##

  raiseAssert("Not implemented!")

proc contains*(s: BlockStore, blk: Cid): bool =
  s.hasBlock(blk)
