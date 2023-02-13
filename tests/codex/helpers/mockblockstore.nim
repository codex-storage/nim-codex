## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/codex/blocktype as bt

import codex/stores/blockstore

type
  MockBlockStore* = ref object of BlockStore
    testBlocks*: seq[bt.Block]
    getBlockCids*: seq[Cid]
    index: int

proc new*(T: type MockBlockStore): T =
  T(
    testBlocks: newSeq[bt.Block](0),
    index: 0
  )

method getBlock*(self: MockBlockStore, cid: Cid): Future[?!Block] =
  self.getBlockCids.add(cid)

method delBlock*(self: MockBlockStore, cid: Cid): Future[?!void] =
  raiseAssert("Not implemented!")

method listBlocks*(
  self: MockBlockStore,
  blockType = BlockType.Manifest): Future[?!BlocksIter] {.async.} =

  var iter = BlocksIter()
  iter.finished = false

  proc next(): Future[?Cid] {.async.} =
    if self.index >= 0 and self.index < len(self.testBlocks):
      let selectedBlock = self.testBlocks[self.index]
      inc self.index
      iter.finished = self.index >= len(self.testBlocks)
      return selectedBlock.cid.some
    return Cid.none

  iter.next = next
  return success iter
