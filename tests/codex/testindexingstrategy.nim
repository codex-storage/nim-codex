import std/sequtils
import pkg/chronos
import pkg/asynctest

import ./helpers

import codex/manifest/indexingstrategy

for offset in @[0, 1, 100]:
  checksuite "Indexing strategies (Offset: " & $offset & ")":
    let
      firstIndex = 0 + offset
      lastIndex = 12 + offset
      nIters = 3
      linear = LinearIndexingStrategy.new(firstIndex, lastIndex, nIters)
      stepped = SteppedIndexingStrategy.new(firstIndex, lastIndex, nIters)

    test "linear":
      check:
        linear.getIndicies(0) == @[0, 1, 2, 3].mapIt(it + offset)
        linear.getIndicies(1) == @[4, 5, 6, 7].mapIt(it + offset)
        linear.getIndicies(2) == @[8, 9, 10, 11].mapIt(it + offset)

    test "stepped":
      check:
        stepped.getIndicies(0) == @[0, 3, 6, 9].mapIt(it + offset)
        stepped.getIndicies(1) == @[1, 4, 7, 10].mapIt(it + offset)
        stepped.getIndicies(2) == @[2, 5, 8, 11].mapIt(it + offset)

checksuite "Indexing strategies - oob":
  let
    linear = LinearIndexingStrategy.new(0, 10, 3)
    stepped = SteppedIndexingStrategy.new(0, 10, 3)

  test "linear":
    expect AssertionDefect:
      discard linear.getIndicies(3)

  test "stepped":
    expect AssertionDefect:
      discard stepped.getIndicies(3)

