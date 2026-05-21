import std/options

import pkg/unittest2

import pkg/storage/blockexchange/engine/scheduler {.all.}

suite "Scheduler":
  const
    WindowSize = 16384'u64
    Threshold = 0.75

  var scheduler: Scheduler

  setup:
    scheduler = Scheduler.new()

  test "Should initialize with correct parameters":
    scheduler.init(1000, 100, WindowSize, Threshold)

    check scheduler.totalBlockCount() == 1000
    check scheduler.batchSizeCount() == 100
    check scheduler.hasWork() == true
    check scheduler.isEmpty() == false

  test "Should take batches in order":
    scheduler.init(1000, 100, WindowSize, Threshold)

    let batch1 = scheduler.take()
    check batch1.isSome
    check batch1.get.start == 0
    check batch1.get.count == 100

    let batch2 = scheduler.take()
    check batch2.isSome
    check batch2.get.start == 100
    check batch2.get.count == 100

  test "Should handle last batch with fewer blocks":
    scheduler.init(250, 100, WindowSize, Threshold)

    discard scheduler.take()
    discard scheduler.take()

    let lastBatch = scheduler.take()
    check lastBatch.isSome
    check lastBatch.get.start == 200
    check lastBatch.get.count == 50

  test "Should mark batch as complete":
    scheduler.init(300, 100, WindowSize, Threshold)

    let batch = scheduler.take()
    check batch.isSome
    check batch.get.start == 0

    scheduler.markComplete(0)

    let next = scheduler.take()
    check next.isSome
    check next.get.start == 100

  test "Should requeue batch at front":
    scheduler.init(500, 100, WindowSize, Threshold)

    let batch1 = scheduler.take()
    check batch1.get.start == 0

    let batch2 = scheduler.take()
    check batch2.get.start == 100

    scheduler.requeueFront(0, 100)

    let requeued = scheduler.take()
    check requeued.isSome
    check requeued.get.start == 0
    check requeued.get.count == 100

  test "Should requeue batch at back":
    scheduler.init(500, 100, WindowSize, Threshold)

    let
      batch1 = scheduler.take()
      batch2 = scheduler.take()

    scheduler.requeueBack(0, 100)
    scheduler.requeueFront(100, 100)

    let first = scheduler.take()
    check first.get.start == 100

    let second = scheduler.take()
    check second.get.start == 0

  test "Should handle partialComplete with single missing range":
    scheduler.init(1000, 100, WindowSize, Threshold)

    let batch = scheduler.take()
    check batch.isSome
    check batch.get.start == 0
    check batch.get.count == 100

    let missingRanges = @[(start: 50'u64, count: 50'u64)]
    scheduler.partialComplete(0, missingRanges)

    let next = scheduler.take()
    check next.isSome
    check next.get.start == 50
    check next.get.count == 50

  test "Should handle partialComplete with multiple missing ranges":
    scheduler.init(1000, 100, WindowSize, Threshold)

    let batch = scheduler.take()
    check batch.isSome
    check batch.get.start == 0

    let missingRanges =
      @[(start: 25'u64, count: 25'u64), (start: 75'u64, count: 25'u64)]
    scheduler.partialComplete(0, missingRanges)

    let next1 = scheduler.take()
    check next1.isSome
    check next1.get.start == 25
    check next1.get.count == 25

    let next2 = scheduler.take()
    check next2.isSome
    check next2.get.start == 75
    check next2.get.count == 25

  test "Should handle partialComplete with non-contiguous missing ranges":
    scheduler.init(1000, 256, WindowSize, Threshold)

    let batch = scheduler.take()
    check batch.isSome
    check batch.get.start == 0
    check batch.get.count == 256

    let missingRanges =
      @[(start: 101'u64, count: 49'u64), (start: 201'u64, count: 55'u64)]
    scheduler.partialComplete(0, missingRanges)

    let next1 = scheduler.take()
    check next1.isSome
    check next1.get.start == 101
    check next1.get.count == 49

    let next2 = scheduler.take()
    check next2.isSome
    check next2.get.start == 201
    check next2.get.count == 55

  test "Should not skip completed batches after partialComplete":
    scheduler.init(500, 100, WindowSize, Threshold)

    let batch1 = scheduler.take()
    check batch1.get.start == 0

    scheduler.markComplete(0)

    let batch2 = scheduler.take()
    check batch2.get.start == 100

    let missingRanges = @[(start: 150'u64, count: 50'u64)]
    scheduler.partialComplete(100, missingRanges)

    let next = scheduler.take()
    check next.isSome
    check next.get.start == 150
    check next.get.count == 50

  test "Should become empty after all batches complete":
    scheduler.init(200, 100, WindowSize, Threshold)

    let batch1 = scheduler.take()
    scheduler.markComplete(batch1.get.start)

    let batch2 = scheduler.take()
    scheduler.markComplete(batch2.get.start)

    check scheduler.isEmpty() == true
    check scheduler.hasWork() == false

  test "Should handle out-of-order completion":
    scheduler.init(500, 100, WindowSize, Threshold)

    let
      batch0 = scheduler.take()
      batch1 = scheduler.take()
      batch2 = scheduler.take()

    check batch0.get.start == 0
    check batch1.get.start == 100
    check batch2.get.start == 200

    scheduler.markComplete(200)
    scheduler.markComplete(0)
    scheduler.markComplete(100)

    let next = scheduler.take()
    check next.isSome
    check next.get.start == 300

  test "Should initialize with range":
    scheduler.initRange(500, 200, 100, WindowSize, Threshold)

    check scheduler.totalBlockCount() == 700
    check scheduler.batchSizeCount() == 100
    check scheduler.completedWatermark() == 500

    let batch1 = scheduler.take()
    check batch1.isSome
    check batch1.get.start == 500
    check batch1.get.count == 100

    let batch2 = scheduler.take()
    check batch2.isSome
    check batch2.get.start == 600
    check batch2.get.count == 100

  test "Should add specific batches":
    scheduler.add(100, 50)
    scheduler.add(300, 75)

    check scheduler.totalBlockCount() == 375
    check scheduler.batchSizeCount() == 50

    let batch1 = scheduler.take()
    check batch1.isSome
    check batch1.get.start == 100
    check batch1.get.count == 50

    let batch2 = scheduler.take()
    check batch2.isSome
    check batch2.get.start == 300
    check batch2.get.count == 75

  test "Should clear scheduler":
    scheduler.init(500, 100, WindowSize, Threshold)

    discard scheduler.take()
    discard scheduler.take()
    scheduler.requeueFront(0, 100)

    scheduler.clear()

    check scheduler.hasWork() == false
    check scheduler.isEmpty() == true
    check scheduler.requeuedCount() == 0
    check scheduler.totalBlockCount() == 0
    check scheduler.batchSizeCount() == 0

    let batch = scheduler.take()
    check batch.isNone

  test "Should return pending batches":
    scheduler.init(500, 100, WindowSize, Threshold)

    check scheduler.pending().len == 0

    discard scheduler.take()
    scheduler.requeueFront(0, 100)

    let pending = scheduler.pending()
    check pending.len == 1
    check pending[0].start == 0
    check pending[0].count == 100

  test "Should return correct requeuedCount":
    scheduler.init(500, 100, WindowSize, Threshold)

    check scheduler.requeuedCount() == 0

    discard scheduler.take()
    discard scheduler.take()
    scheduler.requeueFront(0, 100)
    scheduler.requeueBack(100, 100)

    check scheduler.requeuedCount() == 2

  test "Should return none when exhausted":
    scheduler.init(200, 100, WindowSize, Threshold)

    let
      b1 = scheduler.take()
      b2 = scheduler.take()

    check b1.isSome
    check b2.isSome

    let b3 = scheduler.take()
    check b3.isNone

  test "Should handle single block":
    scheduler.init(1, 100, WindowSize, Threshold)

    let batch = scheduler.take()
    check batch.isSome
    check batch.get.start == 0
    check batch.get.count == 1

    scheduler.markComplete(0)
    check scheduler.isEmpty() == true

  test "Should handle batch size larger than total":
    scheduler.init(50, 100, WindowSize, Threshold)

    let batch = scheduler.take()
    check batch.isSome
    check batch.get.start == 0
    check batch.get.count == 50

    scheduler.markComplete(0)
    check scheduler.isEmpty() == true

  test "Should handle zero blocks":
    scheduler.init(0, 100, WindowSize, Threshold)

    check scheduler.hasWork() == false
    check scheduler.isEmpty() == true

    let batch = scheduler.take()
    check batch.isNone

  test "Should ignore requeue of completed batch":
    scheduler.init(300, 100, WindowSize, Threshold)

    let batch = scheduler.take()
    scheduler.markComplete(batch.get.start)

    scheduler.requeueFront(0, 100)
    scheduler.requeueBack(0, 100)

    check scheduler.requeuedCount() == 0

  test "Should track in-flight batches":
    scheduler.init(300, 100, WindowSize, Threshold)

    let batch = scheduler.take()
    check batch.isSome

    let batch2 = scheduler.take()
    check batch2.isSome
    check batch2.get.start == 100

    scheduler.markComplete(0)
    scheduler.requeueFront(100, 100)

    let batch3 = scheduler.take()
    check batch3.isSome
    check batch3.get.start == 100

  test "Should skip completed batches in requeued":
    scheduler.init(500, 100, WindowSize, Threshold)

    discard scheduler.take()
    scheduler.requeueBack(0, 100)

    discard scheduler.take()
    scheduler.markComplete(0)
    scheduler.requeueBack(0, 100)

    let next = scheduler.take()
    check next.isSome
    check next.get.start == 100

  test "Watermark advances after all sub-ranges of partial batch complete":
    scheduler.init(16, 8, WindowSize, Threshold)

    let batch = scheduler.take()
    check batch.get.start == 0
    check batch.get.count == 8

    let missingRanges = @[
      (start: 1'u64, count: 1'u64),
      (start: 3'u64, count: 1'u64),
      (start: 5'u64, count: 1'u64),
      (start: 7'u64, count: 1'u64),
    ]
    scheduler.partialComplete(0, missingRanges)

    check scheduler.completedWatermark() == 0

    let sub1 = scheduler.take()
    check sub1.get.start == 1
    scheduler.markComplete(1)
    check scheduler.completedWatermark() == 0

    let sub2 = scheduler.take()
    check sub2.get.start == 3
    scheduler.markComplete(3)
    check scheduler.completedWatermark() == 0

    let sub3 = scheduler.take()
    check sub3.get.start == 5
    scheduler.markComplete(5)
    check scheduler.completedWatermark() == 0

    let sub4 = scheduler.take()
    check sub4.get.start == 7
    scheduler.markComplete(7)

    check scheduler.completedWatermark() == 8

  test "Watermark merges OOO after partial batch completes":
    scheduler.init(24, 8, WindowSize, Threshold)

    let
      batch0 = scheduler.take()
      batch1 = scheduler.take()
      batch2 = scheduler.take()
    check batch0.get.start == 0
    check batch1.get.start == 8
    check batch2.get.start == 16

    scheduler.markComplete(8)
    scheduler.markComplete(16)
    check scheduler.completedWatermark() == 0

    scheduler.partialComplete(0, @[(start: 3'u64, count: 1'u64)])
    check scheduler.completedWatermark() == 0

    let sub = scheduler.take()
    check sub.get.start == 3
    scheduler.markComplete(3)

    check scheduler.completedWatermark() == 24
    check scheduler.isEmpty() == true

  test "Nested partials, requeues, OOO merge, multiple partial batches":
    scheduler.init(40, 8, WindowSize, Threshold)

    let
      b0 = scheduler.take()
      b1 = scheduler.take()
      b2 = scheduler.take()
      b3 = scheduler.take()
      b4 = scheduler.take()

    check b0.get.start == 0
    check b4.get.start == 32

    scheduler.markComplete(32)
    check scheduler.completedWatermark() == 0

    scheduler.markComplete(16)
    check scheduler.completedWatermark() == 0

    scheduler.partialComplete(0, @[(start: 2'u64, count: 2'u64)])
    check scheduler.completedWatermark() == 0

    scheduler.partialComplete(
      8, @[(start: 10'u64, count: 3'u64), (start: 13'u64, count: 3'u64)]
    )
    check scheduler.completedWatermark() == 0

    scheduler.markComplete(24)
    check scheduler.completedWatermark() == 0

    let sub1a = scheduler.take()
    check sub1a.get.start == 10
    check sub1a.get.count == 3

    let sub1b = scheduler.take()
    check sub1b.get.start == 13
    check sub1b.get.count == 3

    let sub0a = scheduler.take()
    check sub0a.get.start == 2
    check sub0a.get.count == 2
    scheduler.requeueFront(2, 2)
    check scheduler.completedWatermark() == 0

    scheduler.markComplete(13)
    check scheduler.completedWatermark() == 0

    scheduler.partialComplete(10, @[(start: 11'u64, count: 2'u64)])
    check scheduler.completedWatermark() == 0

    let sub1c = scheduler.take()
    check sub1c.get.start == 11
    check sub1c.get.count == 2

    let sub0b = scheduler.take()
    check sub0b.get.start == 2
    scheduler.markComplete(2)

    check scheduler.completedWatermark() == 8

    scheduler.markComplete(11)

    check scheduler.completedWatermark() == 40
    check scheduler.isEmpty() == true
    check scheduler.hasWork() == false

  test "BlockBatch batchEnd":
    let batch: BlockBatch = (start: 100'u64, count: 50'u64)
    check batch.batchEnd == 150

  test "BlockBatch contains":
    let batch: BlockBatch = (start: 100'u64, count: 50'u64)

    check batch.contains(100) == true
    check batch.contains(149) == true
    check batch.contains(99) == false
    check batch.contains(150) == false

  test "BlockBatch merge":
    let
      batch1: BlockBatch = (start: 100'u64, count: 50'u64)
      batch2: BlockBatch = (start: 140'u64, count: 30'u64)
      batch3: BlockBatch = (start: 200'u64, count: 20'u64)

    let merged1 = merge(batch1, batch2)
    check merged1.isSome
    check merged1.get.start == 100
    check merged1.get.count == 70

    let merged2 = merge(batch1, batch3)
    check merged2.isNone
