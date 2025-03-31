import std/sugar
import pkg/questionable
import pkg/chronos
import pkg/codex/utils/iter
import pkg/codex/utils/safeasynciter

import ../../asynctest
import ../helpers

asyncchecksuite "Test SafeAsyncIter":
  test "Should be finished":
    let iter = SafeAsyncIter[int].empty()

    check:
      iter.finished == true

  test "using with async generator":
    let value = 1
    var intIter = Iter.new(0 ..< 5)
    let expectedSeq = newSeqWith(5, intIter.next())
    intIter = Iter.new(0 ..< 5)
    proc asyncGen(): Future[?!int] {.async: (raw: true, raises: [CancelledError]).} =
      let fut = newFuture[?!int]()
      fut.complete(success(intIter.next()))
      return fut

    let iter = SafeAsyncIter[int].new(asyncGen, () => intIter.finished)

    var collected: seq[int]
    for iFut in iter:
      let iRes = await iFut
      if i =? iRes:
        collected.add(i)
      else:
        fail()

    check collected == expectedSeq
    let nextRes = await iter.next()
    assert nextRes.isFailure
    check nextRes.error.msg == "SafeAsyncIter is finished but next item was requested"

  test "getting async iter for simple sync range iterator":
    let iter1 = SafeAsyncIter[int].new(0 ..< 5)

    var collected: seq[int]
    for iFut in iter1:
      let iRes = await iFut
      if i =? iRes:
        collected.add(i)
      else:
        fail()
    check:
      collected == @[0, 1, 2, 3, 4]

  test "Should map each item using `map`":
    let iter1 = SafeAsyncIter[int].new(0 ..< 5).delayBy(10.millis)

    let iter2 = map[int, string](
      iter1,
      proc(iRes: ?!int): Future[?!string] {.async: (raises: [CancelledError]).} =
        if i =? iRes:
          return success($i)
        else:
          return failure("Some error"),
    )

    var collected: seq[string]

    for fut in iter2:
      if i =? (await fut):
        collected.add(i)
      else:
        fail()

    check:
      collected == @["0", "1", "2", "3", "4"]

  test "Should leave only odd items using `filter`":
    let
      iter1 = SafeAsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = await filter[int](
        iter1,
        proc(i: ?!int): Future[bool] {.async: (raises: [CancelledError]).} =
          if i =? i:
            return (i mod 2) == 1
          else:
            return false,
      )

    var collected: seq[int]

    for fut in iter2:
      if i =? (await fut):
        collected.add(i)
      else:
        fail()

    check:
      collected == @[1, 3]

  test "Should leave only odd items using `mapFilter`":
    let
      iter1 = SafeAsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = await mapFilter[int, string](
        iter1,
        proc(i: ?!int): Future[Option[?!string]] {.async: (raises: [CancelledError]).} =
          if i =? i:
            if (i mod 2) == 1:
              return some(success($i))
          Result[system.string, ref CatchableError].none,
      )

    var collected: seq[string]

    for fut in iter2:
      if i =? (await fut):
        collected.add(i)
      else:
        fail()

    check:
      collected == @["1", "3"]

  test "Collecting errors on `map` when finish on error is true":
    let
      iter1 = SafeAsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = map[int, string](
        iter1,
        proc(i: ?!int): Future[?!string] {.async: (raises: [CancelledError]).} =
          if i =? i:
            if i < 3:
              return success($i)
            else:
              return failure("Error on item: " & $i)
          return failure("Unexpected error"),
      )

    var collectedSuccess: seq[string]
    var collectedFailure: seq[string]

    for fut in iter2:
      without i =? (await fut), err:
        collectedFailure.add(err.msg)
        continue
      collectedSuccess.add(i)

    check:
      collectedSuccess == @["0", "1", "2"]
      collectedFailure == @["Error on item: 3"]
      iter2.finished

  test "Collecting errors on `map` when finish on error is false":
    let
      iter1 = SafeAsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = map[int, string](
        iter1,
        proc(i: ?!int): Future[?!string] {.async: (raises: [CancelledError]).} =
          if i =? i:
            if i < 3:
              return success($i)
            else:
              return failure("Error on item: " & $i)
          return failure("Unexpected error"),
        finishOnErr = false,
      )

    var collectedSuccess: seq[string]
    var collectedFailure: seq[string]

    for fut in iter2:
      without i =? (await fut), err:
        collectedFailure.add(err.msg)
        continue
      collectedSuccess.add(i)

    check:
      collectedSuccess == @["0", "1", "2"]
      collectedFailure == @["Error on item: 3", "Error on item: 4"]
      iter2.finished

  test "Collecting errors on `map` when errors are mixed with successes":
    let
      iter1 = SafeAsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = map[int, string](
        iter1,
        proc(i: ?!int): Future[?!string] {.async: (raises: [CancelledError]).} =
          if i =? i:
            if i == 1 or i == 3:
              return success($i)
            else:
              return failure("Error on item: " & $i)
          return failure("Unexpected error"),
        finishOnErr = false,
      )

    var collectedSuccess: seq[string]
    var collectedFailure: seq[string]

    for fut in iter2:
      without i =? (await fut), err:
        collectedFailure.add(err.msg)
        continue
      collectedSuccess.add(i)

    check:
      collectedSuccess == @["1", "3"]
      collectedFailure == @["Error on item: 0", "Error on item: 2", "Error on item: 4"]
      iter2.finished

  test "Collecting errors on `mapFilter` when finish on error is true":
    let
      iter1 = SafeAsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = await mapFilter[int, string](
        iter1,
        proc(i: ?!int): Future[Option[?!string]] {.async: (raises: [CancelledError]).} =
          if i =? i:
            if i == 1:
              return some(string.failure("Error on item: " & $i))
            elif i < 3:
              return some(success($i))
            else:
              return Result[system.string, ref CatchableError].none
          return some(string.failure("Unexpected error")),
      )

    var collectedSuccess: seq[string]
    var collectedFailure: seq[string]

    for fut in iter2:
      without i =? (await fut), err:
        collectedFailure.add(err.msg)
        continue
      collectedSuccess.add(i)

    check:
      collectedSuccess == @["0"]
      collectedFailure == @["Error on item: 1"]
      iter2.finished

  test "Collecting errors on `mapFilter` when finish on error is false":
    let
      iter1 = SafeAsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = await mapFilter[int, string](
        iter1,
        proc(i: ?!int): Future[Option[?!string]] {.async: (raises: [CancelledError]).} =
          if i =? i:
            if i == 1:
              return some(string.failure("Error on item: " & $i))
            elif i < 3:
              return some(success($i))
            else:
              return Result[system.string, ref CatchableError].none
          return some(string.failure("Unexpected error")),
        finishOnErr = false,
      )

    var collectedSuccess: seq[string]
    var collectedFailure: seq[string]

    for fut in iter2:
      without i =? (await fut), err:
        collectedFailure.add(err.msg)
        continue
      collectedSuccess.add(i)

    check:
      collectedSuccess == @["0", "2"]
      collectedFailure == @["Error on item: 1"]
      iter2.finished

  test "Collecting errors on `filter` when finish on error is false":
    let
      iter1 = SafeAsyncIter[int].new(0 ..< 5)
      iter2 = map[int, string](
        iter1,
        proc(i: ?!int): Future[?!string] {.async: (raises: [CancelledError]).} =
          if i =? i:
            if i == 1 or i == 2:
              return failure("Error on item: " & $i)
            elif i < 4:
              return success($i)
          return failure("Unexpected error"),
        finishOnErr = false,
      )
      iter3 = await filter[string](
        iter2,
        proc(i: ?!string): Future[bool] {.async: (raises: [CancelledError]).} =
          without i =? i, err:
            if err.msg == "Error on item: 1":
              return false
            else:
              return true
          if i == "0":
            return false
          else:
            return true,
        finishOnErr = false,
      )

    var collectedSuccess: seq[string]
    var collectedFailure: seq[string]

    for fut in iter3:
      without i =? (await fut), err:
        collectedFailure.add(err.msg)
        continue
      collectedSuccess.add(i)

    check:
      collectedSuccess == @["3"]
      collectedFailure == @["Error on item: 2", "Unexpected error"]
      iter3.finished

  test "Collecting errors on `filter` when finish on error is true":
    let
      iter1 = SafeAsyncIter[int].new(0 ..< 5)
      iter2 = map[int, string](
        iter1,
        proc(i: ?!int): Future[?!string] {.async: (raises: [CancelledError]).} =
          if i =? i:
            if i == 3:
              return failure("Error on item: " & $i)
            elif i < 3:
              return success($i)
          return failure("Unexpected error"),
        finishOnErr = false,
      )
      iter3 = await filter[string](
        iter2,
        proc(i: ?!string): Future[bool] {.async: (raises: [CancelledError]).} =
          without i =? i, err:
            if err.msg == "Unexpected error":
              return false
            else:
              return true
          if i == "0":
            return false
          else:
            return true,
      )

    var collectedSuccess: seq[string]
    var collectedFailure: seq[string]

    for fut in iter3:
      without i =? (await fut), err:
        collectedFailure.add(err.msg)
        continue
      collectedSuccess.add(i)

    check:
      collectedSuccess == @["1", "2"]
      # On error iterator finishes and returns the error of the item
      # that caused the error = that's why we see it here
      collectedFailure == @["Error on item: 3"]
      iter3.finished

  test "Should propagate cancellation error immediately":
    proc newRaisingFuture[T](
        fromProc: static[string] = ""
    ): Future[T] {.async: (raw: true, raises: [CancelledError]).} =
      let fut = newFuture[T](fromProc)
      return fut

    let fut: Future[Option[?!string]].Raising([CancelledError]) =
      newRaisingFuture[Option[?!string]]("testsafeasynciter")

    let iter1 = SafeAsyncIter[int].new(0 ..< 5).delayBy(10.millis)
    let iter2 = await mapFilter[int, string](
      iter1,
      proc(i: ?!int): Future[Option[?!string]] {.async: (raises: [CancelledError]).} =
        if i =? i:
          if (i < 3):
            return some(success($i))
        return await fut,
    )

    proc cancelFut(): Future[void] {.async.} =
      await sleepAsync(100.millis)
      await fut.cancelAndWait()

    asyncSpawn(cancelFut())

    var collected: seq[string]

    expect CancelledError:
      for fut in iter2:
        if i =? (await fut):
          collected.add(i)
        else:
          fail()

    check:
      collected == @["0", "1"]
      iter2.finished
