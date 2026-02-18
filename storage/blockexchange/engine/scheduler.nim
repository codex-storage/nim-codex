## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[algorithm, deques, sets, tables, options]

type
  BlockBatch* = tuple[start: uint64, count: uint64]

  SelectionPolicy* = enum
    spSequential

  Scheduler* = ref object
    totalBlocks: uint64
    batchSize: uint64
    nextBatchStart: uint64
    requeued: Deque[BlockBatch]
    completedWatermark: uint64
    completedOutOfOrder: HashSet[uint64]
    inFlight: Table[uint64, uint64] # batch start -> block count
    batchRemaining: Table[uint64, uint64] # parent batch start -> remaining blocks

proc new*(T: type Scheduler): Scheduler =
  Scheduler(
    totalBlocks: 0,
    batchSize: 0,
    nextBatchStart: 0,
    requeued: initDeque[BlockBatch](),
    completedWatermark: 0,
    completedOutOfOrder: initHashSet[uint64](),
    inFlight: initTable[uint64, uint64](),
    batchRemaining: initTable[uint64, uint64](),
  )

proc init*(self: Scheduler, totalBlocks: uint64, batchSize: uint64) =
  self.totalBlocks = totalBlocks
  self.batchSize = batchSize
  self.nextBatchStart = 0
  self.requeued.clear()
  self.completedWatermark = 0
  self.completedOutOfOrder.clear()
  self.inFlight.clear()
  self.batchRemaining.clear()

proc initRange*(self: Scheduler, startIndex: uint64, count: uint64, batchSize: uint64) =
  self.totalBlocks = startIndex + count
  self.batchSize = batchSize
  self.nextBatchStart = startIndex
  self.requeued.clear()
  self.completedWatermark = startIndex
  self.completedOutOfOrder.clear()
  self.inFlight.clear()
  self.batchRemaining.clear()

proc updateBatchSize*(self: Scheduler, newBatchSize: uint64) =
  self.batchSize = newBatchSize

proc add*(self: Scheduler, start: uint64, count: uint64) =
  self.requeued.addLast((start: start, count: count))
  let batchEnd = start + count
  if batchEnd > self.totalBlocks:
    self.totalBlocks = batchEnd
  if self.batchSize == 0:
    self.batchSize = count

proc initFromIndices*(self: Scheduler, indices: seq[uint64], batchSize: uint64) =
  let sortedIndices = indices.sorted()
  self.batchSize = batchSize
  self.nextBatchStart = 0
  self.requeued.clear()
  self.completedWatermark = 0
  self.completedOutOfOrder.clear()
  self.inFlight.clear()
  self.batchRemaining.clear()

  var
    batchStart: uint64 = 0
    batchCount: uint64 = 0
    inBatch = false

  for blockIdx in sortedIndices:
    if not inBatch:
      batchStart = blockIdx
      batchCount = 1
      inBatch = true
    elif blockIdx == batchStart + batchCount:
      batchCount += 1
    else:
      self.add(batchStart, batchCount)
      batchStart = blockIdx
      batchCount = 1

    if batchCount >= batchSize:
      self.add(batchStart, batchCount)
      inBatch = false
      batchCount = 0

  if inBatch and batchCount > 0:
    self.add(batchStart, batchCount)

proc generateNextBatchInternal(self: Scheduler): Option[BlockBatch] {.inline.} =
  ## does NOT add to inFlight - we must do that
  while self.nextBatchStart < self.totalBlocks:
    let
      start = self.nextBatchStart
      count = min(self.batchSize, self.totalBlocks - start)
    self.nextBatchStart = start + count

    if start < self.completedWatermark:
      continue
    if start in self.inFlight:
      continue
    if start in self.completedOutOfOrder:
      continue

    return some((start: start, count: count))

  return none(BlockBatch)

proc take*(self: Scheduler): Option[BlockBatch] =
  while self.requeued.len > 0:
    let batch = self.requeued.popFirst()
    if batch.start < self.completedWatermark:
      continue
    if batch.start in self.completedOutOfOrder:
      continue
    self.inFlight[batch.start] = batch.count
    return some(batch)

  let batchOpt = self.generateNextBatchInternal()
  if batchOpt.isSome:
    let batch = batchOpt.get()
    self.inFlight[batch.start] = batch.count
  return batchOpt

proc requeueBack*(self: Scheduler, start: uint64, count: uint64) {.inline.} =
  ## requeue batch at back (peer didn't have it, try later).
  self.inFlight.del(start)
  if start < self.completedWatermark:
    return
  if start in self.completedOutOfOrder:
    return
  self.requeued.addLast((start: start, count: count))

proc requeueFront*(self: Scheduler, start: uint64, count: uint64) {.inline.} =
  ## requeue batch at front (failed/timed out, retry soon).
  self.inFlight.del(start)
  if start < self.completedWatermark:
    return
  if start in self.completedOutOfOrder:
    return
  self.requeued.addFirst((start: start, count: count))

proc advanceWatermark(self: Scheduler, batchStart: uint64) =
  if batchStart == self.completedWatermark:
    self.completedWatermark = batchStart + self.batchSize
    while self.completedWatermark in self.completedOutOfOrder:
      self.completedOutOfOrder.excl(self.completedWatermark)
      self.completedWatermark += self.batchSize
  elif batchStart > self.completedWatermark:
    self.completedOutOfOrder.incl(batchStart)

proc findPartialParent(self: Scheduler, start: uint64): Option[uint64] =
  for parent, remaining in self.batchRemaining:
    if start >= parent and start < parent + self.batchSize:
      return some parent
  return none(uint64)

proc markComplete*(self: Scheduler, start: uint64) =
  let count = self.inFlight.getOrDefault(start, 0'u64)
  self.inFlight.del(start)

  let parent = self.findPartialParent(start)
  if parent.isSome:
    self.batchRemaining.withValue(parent.get, remaining):
      remaining[] -= count
      if remaining[] <= 0:
        self.batchRemaining.del(parent.get)
        self.advanceWatermark(parent.get)
    return

  self.advanceWatermark(start)

proc partialComplete*(
    self: Scheduler, originalStart: uint64, missingRanges: seq[BlockBatch]
) =
  let originalCount = self.inFlight.getOrDefault(originalStart, self.batchSize)
  self.inFlight.del(originalStart)

  var totalMissing: uint64 = 0
  for batch in missingRanges:
    totalMissing += batch.count

  let parent = self.findPartialParent(originalStart)
  if parent.isSome:
    let delivered = originalCount - totalMissing
    self.batchRemaining.withValue(parent.get, remaining):
      remaining[] -= delivered
  else:
    self.batchRemaining[originalStart] = totalMissing

  for i in countdown(missingRanges.len - 1, 0):
    let batch = missingRanges[i]
    self.requeued.addFirst(batch)

proc isEmpty*(self: Scheduler): bool =
  self.completedWatermark >= self.totalBlocks and self.requeued.len == 0 and
    self.inFlight.len == 0

proc completedWatermark*(self: Scheduler): uint64 =
  self.completedWatermark

proc hasWork*(self: Scheduler): bool {.inline.} =
  self.requeued.len > 0 or self.nextBatchStart < self.totalBlocks

proc requeuedCount*(self: Scheduler): int {.inline.} =
  self.requeued.len

proc pending*(self: Scheduler): seq[BlockBatch] =
  var res = newSeqUninit[BlockBatch](self.requeued.len)
  for i, batch in self.requeued:
    res[i] = batch
  return res

proc clear*(self: Scheduler) =
  self.requeued.clear()
  self.completedOutOfOrder.clear()
  self.inFlight.clear()
  self.batchRemaining.clear()
  self.nextBatchStart = 0
  self.completedWatermark = 0
  self.totalBlocks = 0
  self.batchSize = 0

proc totalBlockCount*(self: Scheduler): uint64 =
  self.totalBlocks

proc batchSizeCount*(self: Scheduler): uint64 =
  self.batchSize

proc batchEnd*(batch: BlockBatch): uint64 =
  batch.start + batch.count

proc contains*(batch: BlockBatch, blockIndex: uint64): bool =
  blockIndex >= batch.start and blockIndex < batch.batchEnd

proc merge*(a, b: BlockBatch): Option[BlockBatch] =
  if a.batchEnd < b.start or b.batchEnd < a.start:
    return none(BlockBatch)

  let
    newStart = min(a.start, b.start)
    newEnd = max(a.batchEnd, b.batchEnd)
  some((start: newStart, count: newEnd - newStart))
