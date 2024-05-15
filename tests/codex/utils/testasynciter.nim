import std/sugar

import pkg/questionable
import pkg/chronos
import pkg/codex/utils/asynciter

import ../../asynctest
import ../helpers

asyncchecksuite "Test AsyncIter":

  test "Should be finished":
    let iter = emptyAsyncIter[int]()

    check:
      iter.finished == true

  test "Should multiply each item by 2 using `map`":
    let
      iter1 = newIter(1..<5)
      iter2 = mapAsync[int, int](iter1,
        proc (i: int): Future[int] {.async.} =
          i * 2
      )

    var items: seq[int]

    for fut in iter2:
      items.add(await fut)

    check:
      items == @[2, 4, 6, 8]

  test "Should leave only odd items using `filter`":
    let
      iter1 = newIter(0..<5)
      iter2 = mapAsync[int, int](iter1,
        proc (i: int): Future[int] {.async.} =
          await sleepAsync((i * 10).millis)
          i
      )
      iter3 = await filter[int](iter2,
        proc (i: int): Future[bool] {.async.} =
          (i mod 2) == 1
      )

    var items: seq[int]

    for fut in iter3:
      items.add(await fut)

    check:
      items == @[1, 3]

  test "Should leave only odd items using `mapFilter`":
    let
      iter1 = newIter(0..<5)
      iter2 = mapAsync[int, int](iter1,
        proc (i: int): Future[int] {.async.} =
          await sleepAsync((i * 10).millis)
          i
      )
      iter3 = await mapFilter[int, string](iter2,
        proc (i: int): Future[?string] {.async.} =
          if (i mod 2) == 1:
            some($i)
          else:
            string.none
      )

    var items: seq[string]

    for fut in iter3:
      items.add(await fut)

    check:
      items == @["1", "3"]
