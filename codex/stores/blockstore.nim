## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/times
import pkg/upraises

push: {.upraises: [].}

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ../blocktype

export blocktype, libp2p

type
  BlockNotFoundError* = object of CodexError

  BlockType* {.pure.} = enum
    Manifest, Block, Both

  GetNext* = proc(): Future[?Cid] {.upraises: [], gcsafe, closure.}

  BlocksIter* = ref object
    finished*: bool
    next*: GetNext

  BlockStore* = ref object of RootObj

iterator items*(self: BlocksIter): Future[?Cid] =
  while not self.finished:
    yield self.next()

method getBlock*(self: BlockStore, cid: Cid): Future[?!Block] {.base.} =
  ## Get a block from the blockstore
  ##

  raiseAssert("Not implemented!")

method putBlock*(
  self: BlockStore,
  blk: Block,
  ttl = times.Duration.none): Future[?!void] {.base.} =
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

method listBlocks*(
  self: BlockStore,
  blockType = BlockType.Manifest): Future[?!BlocksIter] {.base.} =
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
