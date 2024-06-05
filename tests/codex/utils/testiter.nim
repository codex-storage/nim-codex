import std/sugar

import pkg/questionable
import pkg/chronos
import pkg/codex/utils/iter

import ../../asynctest
import ../helpers

checksuite "Test Iter":

  test "Should be finished":
    let iter = emptyIter[int]()

    check:
      iter.finished == true

  test "Should be iterable with `items`":
    let iter = newIter(1..<5)

    let items =
      collect:
        for v in iter:
          v

    check:
      items == @[1, 2, 3, 4]

  test "Should be iterable with `pairs`":
    let iter = newIter(1..<5)

    let pairs =
      collect:
        for i, v in iter:
          (i, v)

    check:
      pairs == @[(0, 1), (1, 2), (2, 3), (3, 4)]

  test "Should multiply each item by 2 using `map`":
    let iter = newIter(1..<5)
      .map((i: int) => i * 2)

    check:
      iter.toSeq() == @[2, 4, 6, 8]

  test "Should leave only odd items using `filter`":
    let iter = newIter(0..<5)
      .filter((i: int) => (i mod 2) == 1)

    check:
      iter.toSeq() == @[1, 3]

  test "Should leave only odd items using `mapFilter`":
    let
      iter1 = newIter(0..<5)
      iter2 = mapFilter[int, string](iter1,
        proc(i: int): ?string =
          if (i mod 2) == 1:
            some($i)
          else:
            string.none
      )

    check:
      iter2.toSeq() == @["1", "3"]

  test "Should finish on error":
    let
      iter = newIter(0..<5)
        .map(
          proc (i: int): int =
            raise newException(CatchableError, "Some error")
        )

    check:
      not iter.finished()

    expect CatchableError:
      discard iter.next()

    check:
      iter.finished()
