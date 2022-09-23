## Nim-Codex
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
  OnBlock* = proc(cid: Cid): Future[void] {.upraises: [], gcsafe.}
  BlockStore* = ref object of RootObj

method getBlock*(self: BlockStore, cid: Cid): Future[?!Block] {.base.} =
  ## Get a block from the blockstore
  ##

  raiseAssert("Not implemented!")

method putBlock*(self: BlockStore, blk: Block): Future[?!void] {.base.} =
  ## Put a block to the blockstore
  ##

  raiseAssert("Not implemented!")

method delBlock*(self: BlockStore, cid: Cid): Future[?!void] {.base.} =
  ## Delete a block from the blockstore
  ##

  raiseAssert("Not implemented!")

method hasBlock*(self: BlockStore, cid: Cid): Future[?!bool] {.base.} =
  ## Check if the block exists in the blockstore
  ##

  raiseAssert("Not implemented!")

method listBlocks*(self: BlockStore, onBlock: OnBlock): Future[?!void] {.base.} =
  ## Get the list of blocks in the BlockStore. This is an intensive operation
  ##

  raiseAssert("Not implemented!")

method close*(self: Blockstore): Future[void] {.base.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  raiseAssert("Not implemented!")

proc contains*(self: BlockStore, blk: Cid): Future[bool] {.async.} =
  ## Check if the block exists in the blockstore.
  ## Return false if error encountered
  ##

  return (await self.hasBlock(blk)) |? false
