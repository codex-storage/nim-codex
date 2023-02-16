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
import codex/clock
import codex/systemclock

type
  BlockMaintainer* = ref object of RootObj
    repoStore: RepoStore
    interval: Duration
    timer: Timer
    clock: Clock
    numberOfBlocksPerInterval: int
    offset: int

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
    clock: clock,
    numberOfBlocksPerInterval: numberOfBlocksPerInterval,
    offset: 0
  )

proc runBlockCheck(self: BlockMaintainer): Future[void] {.async.} =
  var blockCidsToDelete = newSeq[Cid](0)
  proc processBlockExpiration(self: BlockMaintainer, be: BlockExpiration) =
    if be.expiration < self.clock.now:
      blockCidsToDelete.add(be.cid)
    else:
      inc self.offset

  proc deleteAllExpiredBlocks(self: BlockMaintainer): Future[void] {.async.} =
    for cid in blockCidsToDelete:
      if isErr (await self.repoStore.delBlock(cid)):
        trace "Unable to delete block from repoStore"

  let expirations = await self.repoStore.getBlockExpirations(
    maxNumber = self.numberOfBlocksPerInterval,
    offset = self.offset
  )

  without iter =? expirations, err:
    trace "Unable to obtain blockExpirations iterator from repoStore"
    return

  var numberReceived = 0
  while not iter.finished:
    if be =? await iter.next():
      inc numberReceived
      self.processBlockExpiration(be)

  await self.deleteAllExpiredBlocks()

  # If we received fewer blockExpirations from the iterator than we asked for,
  # We're at the end of the dataset and should start from 0 next time.
  if numberReceived < self.numberOfBlocksPerInterval:
    self.offset = 0

proc start*(self: BlockMaintainer) =
  proc onTimer(): Future[void] {.async.} =
    try:
      await self.runBlockCheck()
    except CatchableError as exc:
      error "Unexpected exception in BlockMaintainer.onTimer(): ", exc

  self.timer.start(onTimer, self.interval)

proc stop*(self: BlockMaintainer): Future[void] {.async.} =
  await self.timer.stop()
