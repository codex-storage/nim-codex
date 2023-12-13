import std/sugar

import pkg/questionable
import pkg/chronos
import pkg/upraises
import pkg/codex/utils/asynciter

import ../../asynctest
import ../helpers

asyncchecksuite "Test AsyncIter":

  test "Should be finished":
    let iter = emptyIter[int]()

    check:
      iter.finished == true

  test "Should be iterable with `items()`":
    let iter = Iter
      .fromSlice(1..<5)

    let items =
      collect:
        for v in iter:
          v

    check:
      items == @[1, 2, 3, 4]

  test "Should be iterable with `pairs()`":
    let iter = Iter
      .fromSlice(1..<5)

    let pairs =
      collect:
        for i, v in iter:
          (i, v)

    check:
      pairs == @[(0, 1), (1, 2), (2, 3), (3, 4)]

  test "Should double items using `map`":
    let iter = Iter
      .fromSlice(1..<5)
      .map((i: int) => i * 2)

    check:
      iter.toSeq() == @[2, 4, 6, 8]

  test "Should leave only odd items using `filter`":
    let iter = Iter
      .fromSlice(0..<5)
      .filter((i: int) => (i mod 2) == 1)

    check:
      iter.toSeq() == @[1, 3]
