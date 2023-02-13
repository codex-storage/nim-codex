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
    timer: Timer[BlockMaintainer]
    checker: BlockChecker,
    numberOfBlocksPerInterval: int

method checkBlock(blockChecker: BlockChecker, blockStore: BlockStore, cid: Cid): Future[void] {.async, base.} =
  discard

proc new*(T: type BlockMaintainer,
    blockStore: BlockStore,
    interval: Duration,
    # I want to default the timer here, like so:
    # timer = Timer[BlockMaintainer].new(),
    # but the generic messes this up somehow. Plz help.
    timer: Timer[BlockMaintainer],
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

proc onTimer(self: BlockMaintainer): Future[void] {.async.} =
  if iter =? await self.blockStore.listBlocks():
    while not iter.finished:
      if currentBlockCid =? await iter.next():
        await self.checker.checkBlock(self.blockStore, currentBlockCid)

proc start*(self: BlockMaintainer) =
  self.timer.start(self, onTimer, self.interval)

proc stop*(self: BlockMaintainer): Future[void] {.async.} =
  await self.timer.stop()
