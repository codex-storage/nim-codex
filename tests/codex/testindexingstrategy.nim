import std/sequtils
import pkg/chronos
import pkg/asynctest

import ./helpers

import codex/manifest/indexingstrategy

for offset in @[0, 1, 2, 100]:
  checksuite "Indexing strategies (Offset: " & $offset & ")":
    let
      firstIndex = 0 + offset
      lastIndex = 12 + offset
      nIters = 3
      linear = LinearIndexingStrategy.new(firstIndex, lastIndex, nIters)
      stepped = SteppedIndexingStrategy.new(firstIndex, lastIndex, nIters)

    test "linear":
      check:
        linear.getIndicies(0) == @[0, 1, 2, 3, 4].mapIt(it + offset)
        linear.getIndicies(1) == @[5, 6, 7, 8, 9].mapIt(it + offset)
        linear.getIndicies(2) == @[10, 11, 12].mapIt(it + offset)

    test "stepped":
      check:
        stepped.getIndicies(0) == @[0, 3, 6, 9, 12].mapIt(it + offset)
        stepped.getIndicies(1) == @[1, 4, 7, 10].mapIt(it + offset)
        stepped.getIndicies(2) == @[2, 5, 8, 11].mapIt(it + offset)

checksuite "Indexing strategies":
  let
    linear = LinearIndexingStrategy.new(0, 10, 3)
    stepped = SteppedIndexingStrategy.new(0, 10, 3)

  test "smallest range 0":
    let
      l = LinearIndexingStrategy.new(0, 0, 1)
      s = SteppedIndexingStrategy.new(0, 0, 1)
    check:
      l.getIndicies(0) == @[0]
      s.getIndicies(0) == @[0]

  test "smallest range 1":
    let
      l = LinearIndexingStrategy.new(0, 1, 1)
      s = SteppedIndexingStrategy.new(0, 1, 1)
    check:
      l.getIndicies(0) == @[0, 1]
      s.getIndicies(0) == @[0, 1]

  test "first index must be smaller than last index":
    expect AssertionDefect:
      discard LinearIndexingStrategy.new(10, 0, 1)

  test "numberOfIterations must be greater than zero":
    expect AssertionDefect:
      discard LinearIndexingStrategy.new(0, 10, 0)

  test "linear - oob":
    expect AssertionDefect:
      discard linear.getIndicies(3)

  test "stepped - oob":
    expect AssertionDefect:
      discard stepped.getIndicies(3)

