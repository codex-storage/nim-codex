import std/[sets, options, hashes, random]

import pkg/unittest2
import pkg/libp2p/cid

import pkg/storage/blockexchange/engine/downloadcontext {.all.}
import pkg/storage/blockexchange/engine/scheduler {.all.}

import ../../examples

suite "Random Window Cursor":
  test "Produces all windows exactly once (full permutation)":
    for totalWindows in [
      1'u64, 2, 3, 5, 7, 10, 16, 17, 31, 32, 63, 64, 100, 127, 128, 255, 256, 1000
    ]:
      let
        windowSize = 100'u64
        totalBlocks = totalWindows * windowSize
      var
        cursor = initRandomWindowCursor(totalBlocks, windowSize)
        seen = initHashSet[uint64]()

      seen.incl(cursor.currentWindow().start div windowSize)

      for i in 1'u64 ..< totalWindows:
        check cursor.advance()
        let windowIdx = cursor.currentWindow().start div windowSize
        check windowIdx < totalWindows
        check windowIdx notin seen
        seen.incl(windowIdx)

      check seen.len.uint64 == totalWindows
      check cursor.isDone

  test "Different inits produce different permutations":
    let
      windowSize = 100'u64
      totalBlocks = 10000'u64
      totalWindows = totalBlocks div windowSize

    var
      cursor1 = initRandomWindowCursor(totalBlocks, windowSize)
      cursor2 = initRandomWindowCursor(totalBlocks, windowSize)
      same = 0

    if cursor1.currentWindow().start == cursor2.currentWindow().start:
      same += 1

    for i in 1'u64 ..< totalWindows:
      discard cursor1.advance()
      discard cursor2.advance()
      if cursor1.currentWindow().start == cursor2.currentWindow().start:
        same += 1

    check same < 50

  test "Edge case: single window":
    var cursor = initRandomWindowCursor(50, 100)
    check cursor.currentWindow().start == 0
    check cursor.currentWindow().count == 50
    check cursor.isDone

  test "Edge case: two windows":
    var
      cursor = initRandomWindowCursor(200, 100)
      seen = initHashSet[uint64]()
    seen.incl(cursor.currentWindow().start)
    check cursor.advance()
    seen.incl(cursor.currentWindow().start)
    check seen.len == 2
    check 0'u64 in seen
    check 100'u64 in seen
    check cursor.isDone

  test "Last window is truncated when totalBlocks not divisible by windowSize":
    var
      cursor = initRandomWindowCursor(350, 100)
      foundShort = false

    if cursor.currentWindow().count < 100:
      foundShort = true
    while cursor.advance():
      if cursor.currentWindow().count < 100:
        foundShort = true
        check cursor.currentWindow().count == 50
    check foundShort

suite "DownloadContext Random Windows":
  test "initRandomWindows sets up first window":
    let
      ctx = DownloadContext.new(
        toDownloadDesc(Cid.example, 100000, 65536, selectionPolicy = spRandomWindow)
      )
      (start, count) = ctx.currentPresenceWindow()
    check count > 0
    check start < ctx.totalBlocks
    check start + count <= ctx.totalBlocks

  test "advanceWindow cycles through all windows":
    let
      blockSize = 65536'u32
      windowSize = computeWindowSize(blockSize)
      totalBlocks = windowSize * 5
      ctx = DownloadContext.new(
        toDownloadDesc(
          Cid.example, totalBlocks, blockSize, selectionPolicy = spRandomWindow
        )
      )

    var windowStarts = initHashSet[uint64]()
    windowStarts.incl(ctx.currentPresenceWindow().start)

    for i in 1 ..< 5:
      while true:
        let batch = ctx.scheduler.take()
        if batch.isNone:
          break
        ctx.scheduler.markComplete(batch.get().start)

      check ctx.needsNextPresenceWindow()
      discard ctx.advancePresenceWindow()
      windowStarts.incl(ctx.currentPresenceWindow().start)

    check windowStarts.len == 5
    check not ctx.needsNextPresenceWindow()

  test "scheduler.isEmpty returns true when all batches complete":
    let ctx = DownloadContext.new(
      toDownloadDesc(Cid.example, 100, 65536, selectionPolicy = spRandomWindow)
    )
    while true:
      let batch = ctx.scheduler.take()
      if batch.isNone:
        break
      ctx.scheduler.markComplete(batch.get().start)
    check ctx.scheduler.isEmpty

  test "File smaller than 1 window (single window)":
    let
      blockSize = 65536'u32
      windowSize = computeWindowSize(blockSize)
      totalBlocks = windowSize div 2
      ctx = DownloadContext.new(
        toDownloadDesc(
          Cid.example, totalBlocks, blockSize, selectionPolicy = spRandomWindow
        )
      )
      (start, count) = ctx.currentPresenceWindow()

    check start == 0
    check count == totalBlocks
    check not ctx.needsNextPresenceWindow()

  test "File exactly N windows":
    let
      blockSize = 65536'u32
      windowSize = computeWindowSize(blockSize)
      totalBlocks = windowSize * 3
      ctx = DownloadContext.new(
        toDownloadDesc(
          Cid.example, totalBlocks, blockSize, selectionPolicy = spRandomWindow
        )
      )

    var count = 1
    while true:
      while true:
        let batch = ctx.scheduler.take()
        if batch.isNone:
          break
        ctx.scheduler.markComplete(batch.get().start)

      if not ctx.needsNextPresenceWindow():
        break
      discard ctx.advancePresenceWindow()
      count += 1

    check count == 3
