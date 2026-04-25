import std/sets
import std/importutils

import pkg/unittest2
import pkg/chronos

import pkg/storage/blockexchange/engine/downloadcontext {.all.}
import pkg/storage/blockexchange/engine/scheduler {.all.}

privateAccess(BroadcastAvailabilityTracker)

suite "BroadcastAvailabilityTracker (sequential OOO)":
  const
    WindowSize = 16384'u64
    Threshold = 0.75
    BatchSize = 100'u64
    TotalBlocks = 100_000'u64

  var
    tracker: BroadcastAvailabilityTracker
    sched: Scheduler

  template expireInterval() =
    tracker.lastBroadcastTime = Moment.now() - 1.hours
    tracker.broadcastInterval = 1.milliseconds

  setup:
    sched = Scheduler.new()
    sched.init(TotalBlocks, BatchSize, WindowSize, Threshold)
    tracker = BroadcastAvailabilityTracker(
      policy: spSequential,
      lastBroadcastedWatermark: 0,
      broadcastedOutOfOrder: initHashSet[uint64](),
      pendingOOOSnapshot: initHashSet[uint64](),
      lastBroadcastTime: Moment.now(),
      broadcastInterval: 1.hours,
    )

  test "OOO batch triggers broadcast when watermark has not moved":
    discard sched.take()
    discard sched.take()
    sched.markComplete(100)

    check sched.completedWatermark() == 0
    check tracker.shouldBroadcast(sched)

    let ranges = tracker.getRanges(sched)
    check ranges == @[(start: 100'u64, count: BatchSize)]
    check tracker.pendingOOOSnapshot == toHashSet([100'u64])

    tracker.markBroadcasted(sched)
    check tracker.broadcastedOutOfOrder == toHashSet([100'u64])
    check tracker.lastBroadcastedWatermark == 0

  test "Already-broadcast OOO is not re-emitted next cycle":
    for _ in 0 ..< 3:
      discard sched.take()
    sched.markComplete(100)
    discard tracker.getRanges(sched)
    tracker.markBroadcasted(sched)

    sched.markComplete(200)
    check tracker.shouldBroadcast(sched)
    let ranges = tracker.getRanges(sched)
    check ranges == @[(start: 200'u64, count: BatchSize)]

  test "Multiple new OOO batches are all emitted in a single broadcast":
    for _ in 0 ..< 4:
      discard sched.take()
    sched.markComplete(100)
    sched.markComplete(200)
    sched.markComplete(300)

    let ranges = tracker.getRanges(sched)
    check ranges.len == 3

    var starts: HashSet[uint64]
    for r in ranges:
      check r.count == BatchSize
      starts.incl(r.start)
    check starts == toHashSet([100'u64, 200, 300])
    check tracker.pendingOOOSnapshot == toHashSet([100'u64, 200, 300])

  test "Watermark absorbing already-broadcast OOO produces prefix overlap":
    discard sched.take()
    discard sched.take()
    sched.markComplete(100)
    discard tracker.getRanges(sched)
    tracker.markBroadcasted(sched)
    check tracker.broadcastedOutOfOrder == toHashSet([100'u64])

    sched.markComplete(0)
    check sched.completedWatermark() == 200

    expireInterval()
    check tracker.shouldBroadcast(sched)

    let ranges = tracker.getRanges(sched)
    check ranges == @[(start: 0'u64, count: 200'u64)]

    tracker.markBroadcasted(sched)
    check tracker.broadcastedOutOfOrder.len == 0

  test "No new blocks and no new OOO → shouldBroadcast stays false":
    expireInterval()
    check not tracker.shouldBroadcast(sched)

  test "Prefix-only broadcast fires only after the interval elapses":
    discard sched.take()
    sched.markComplete(0)

    check not tracker.shouldBroadcast(sched)

    expireInterval()
    check tracker.shouldBroadcast(sched)

    let ranges = tracker.getRanges(sched)
    check ranges == @[(start: 0'u64, count: BatchSize)]
    check tracker.pendingOOOSnapshot.len == 0

    tracker.markBroadcasted(sched)
    check tracker.lastBroadcastedWatermark == BatchSize
    check tracker.broadcastedOutOfOrder.len == 0

  test "OOO arriving between getRanges and markBroadcasted is not marked":
    for _ in 0 ..< 3:
      discard sched.take()
    sched.markComplete(100)

    let ranges = tracker.getRanges(sched)
    check ranges == @[(start: 100'u64, count: BatchSize)]
    check tracker.pendingOOOSnapshot == toHashSet([100'u64])

    sched.markComplete(200)

    tracker.markBroadcasted(sched)
    check tracker.broadcastedOutOfOrder == toHashSet([100'u64])
    check 200'u64 notin tracker.broadcastedOutOfOrder

    check tracker.shouldBroadcast(sched)
    let ranges2 = tracker.getRanges(sched)
    check ranges2 == @[(start: 200'u64, count: BatchSize)]
    check tracker.pendingOOOSnapshot == toHashSet([200'u64])

  test "getRanges clears stale snapshot when mark was skipped":
    discard sched.take()
    discard sched.take()
    sched.markComplete(100)
    discard tracker.getRanges(sched)
    check tracker.pendingOOOSnapshot.len == 1

    sched.markComplete(0)
    check sched.completedWatermark() == 200

    let ranges = tracker.getRanges(sched)
    check ranges == @[(start: 0'u64, count: 200'u64)]
    check tracker.pendingOOOSnapshot.len == 0
