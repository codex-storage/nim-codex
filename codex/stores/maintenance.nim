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

import codex/stores/repostore
import codex/utils/timer
import codex/systemclock

type
  BlockMaintainer* = ref object of RootObj
    repoStore: RepoStore
    interval: Duration
    timer: Timer
    clock: Clock
    numberOfBlocksPerInterval: int
    currentIterator: ?BlocksIter

proc new*(T: type BlockMaintainer,
    repoStore: RepoStore,
    interval: Duration,
    timer = Timer.new(),
    clock: Clock = SystemClock.new(),
    numberOfBlocksPerInterval = 100
    ): T =
  T(
    repoStore: repoStore,
    interval: interval,
    timer: timer,
    clock: clock
    numberOfBlocksPerInterval: numberOfBlocksPerInterval,
    currentIterator: BlocksIter.none
  )

proc isCurrentIteratorValid(self: BlockMaintainer): bool =
  if iter =? self.currentIterator:
    return not iter.finished
  false

proc getCurrentIterator(self: BlockMaintainer): Future[?!BlocksIter] {.async.} =
  if not self.isCurrentIteratorValid():
    self.currentIterator = (await self.repoStore.listBlocks()).option
  if iter =? self.currentIterator:
    return success iter
  let error = newException(CodexError, "Unable to obtain block iterator")
  return failure error

proc runBlockCheck(self: BlockMaintainer): Future[void] {.async.} =
  var blocksLeft = self.numberOfBlocksPerInterval

  proc processOneBlock(iter: BlocksIter): Future[void] {.async.} =
    if currentBlockCid =? await iter.next():
      dec blocksLeft
      await self.checker.checkBlock(self.repoStore, currentBlockCid)

  while blocksLeft > 0 and iter =? await self.getCurrentIterator():
    await processOneBlock(iter)

proc start*(self: BlockMaintainer) =
  proc onTimer(): Future[void] {.async.} =
    try:
      await self.runBlockCheck()
    except CatchableError as exc:
      error "Unexpected exception in BlockMaintainer.onTimer(): ", exc

  self.timer.start(onTimer, self.interval)

proc stop*(self: BlockMaintainer): Future[void] {.async.} =
  await self.timer.stop()
