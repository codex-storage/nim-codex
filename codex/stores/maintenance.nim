## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Store maintenance module
## Looks for and removes expired blocks from blockstores.

import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results

import codex/stores/blockstore
import codex/utils/timer

type
  BlockChecker* = ref object of RootObj
  BlockMaintainer* = ref object of RootObj
    blockStore: BlockStore
    interval: Duration
    timer: Timer
    checker: BlockChecker
    numberOfBlocksPerInterval: int

method checkBlock(blockChecker: BlockChecker, blockStore: BlockStore, cid: Cid): Future[void] {.async, base.} =
  discard

proc new*(T: type BlockMaintainer,
    blockStore: BlockStore,
    interval: Duration,
    timer = Timer.new(),
    blockChecker = BlockChecker.new(),
    numberOfBlocksPerInterval = 100
    ): T =
  T(
    blockStore: blockStore,
    interval: interval,
    timer: timer,
    checker: blockChecker,
    numberOfBlocksPerInterval: numberOfBlocksPerInterval
  )

proc checkBlocks(self: BlockMaintainer): Future[void] {.async.} =
  var blocksLeft = self.numberOfBlocksPerInterval
  while blocksLeft > 0:
    if iter =? await self.blockStore.listBlocks():
      while not iter.finished and blocksLeft > 0:
        dec blocksLeft
        if currentBlockCid =? await iter.next():
          await self.checker.checkBlock(self.blockStore, currentBlockCid)

proc start*(self: BlockMaintainer) =
  proc onTimer(): Future[void] {.async.} =
    await self.checkBlocks()

  self.timer.start(onTimer, self.interval)

proc stop*(self: BlockMaintainer): Future[void] {.async.} =
  await self.timer.stop()
