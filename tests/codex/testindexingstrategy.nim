import std/sequtils
import std/algorithm
import pkg/chronos

import pkg/codex/utils/asynciter

import ../asynctest
import ./helpers

import pkg/codex/indexingstrategy

for offset in @[0, 1, 2, 100]:
  suite "Indexing strategies (Offset: " & $offset & ")":
    let
      firstIndex = 0 + offset
      lastIndex = 12 + offset
      nIters = 3
      totalGroups = 1
      linear = LinearStrategy.init(firstIndex, lastIndex, nIters, totalGroups)
      stepped = SteppedStrategy.init(firstIndex, lastIndex, nIters, totalGroups)

    test "linear":
      check:
        toSeq(linear.getIndices(0)) == @[0, 1, 2, 3, 4].mapIt(it + offset)
        toSeq(linear.getIndices(1)) == @[5, 6, 7, 8, 9].mapIt(it + offset)
        toSeq(linear.getIndices(2)) == @[10, 11, 12].mapIt(it + offset)

    test "stepped":
      check:
        toSeq(stepped.getIndices(0)) == @[0, 3, 6, 9, 12].mapIt(it + offset)
        toSeq(stepped.getIndices(1)) == @[1, 4, 7, 10].mapIt(it + offset)
        toSeq(stepped.getIndices(2)) == @[2, 5, 8, 11].mapIt(it + offset)

suite "Indexing strategies":
  let
    totalGroups = 1
    linear = LinearStrategy.init(0, 10, 3, totalGroups)
    stepped = SteppedStrategy.init(0, 10, 3, totalGroups)

  test "smallest range 0":
    let
      l = LinearStrategy.init(0, 0, 1, totalGroups)
      s = SteppedStrategy.init(0, 0, 1, totalGroups)
    check:
      toSeq(l.getIndices(0)) == @[0]
      toSeq(s.getIndices(0)) == @[0]

  test "smallest range 1":
    let
      l = LinearStrategy.init(0, 1, 1, totalGroups)
      s = SteppedStrategy.init(0, 1, 1, totalGroups)
    check:
      toSeq(l.getIndices(0)) == @[0, 1]
      toSeq(s.getIndices(0)) == @[0, 1]

  test "first index must be smaller than last index":
    expect IndexingWrongIndexError:
      discard LinearStrategy.init(10, 0, 1, totalGroups)

  test "iterations must be greater than zero":
    expect IndexingWrongIterationsError:
      discard LinearStrategy.init(0, 10, 0, totalGroups)

  test "totalGroups must be greater than zero":
    expect IndexingWrongTotalGroupsError:
      discard LinearStrategy.init(1, 1, 1, 0)

  test "should split elements evenly when possible":
    let l = LinearStrategy.init(0, 11, 3, totalGroups)
    check:
      toSeq(l.getIndices(0)) == @[0, 1, 2, 3].mapIt(it)
      toSeq(l.getIndices(1)) == @[4, 5, 6, 7].mapIt(it)
      toSeq(l.getIndices(2)) == @[8, 9, 10, 11].mapIt(it)

  test "linear - oob":
    expect IndexingError:
      discard linear.getIndices(3)

  test "stepped - oob":
    expect IndexingError:
      discard stepped.getIndices(3)
