import std/sequtils
import pkg/chronos
import pkg/asynctest

import ./helpers

import codex/manifest/indexingstrategy

for offset in @[0, 1, 100]:
  checksuite "Indexing strategies (Offset: " & $offset & ")":
    let
      firstIndex = 0 + offset
      lastIndex = 9 + offset
      nIters = 3
      linear = LinearIndexingStrategy.new(firstIndex, lastIndex, nIters)
      stepped = SteppedIndexingStrategy.new(firstIndex, lastIndex, nIters)

    test "linear":
      check:
        linear.getIndicies(0) == @[0, 1, 2].mapIt(it + offset)
        linear.getIndicies(1) == @[3, 4, 5].mapIt(it + offset)
        linear.getIndicies(2) == @[6, 7, 8].mapIt(it + offset)

    test "linear - oob":
      expect AssertionDefect:
        discard linear.getIndicies(3)

    test "stepped":
      check:
        stepped.getIndicies(0) == @[0, 3, 6].mapIt(it + offset)
        stepped.getIndicies(1) == @[1, 4, 7].mapIt(it + offset)
        stepped.getIndicies(2) == @[2, 5, 8].mapIt(it + offset)

    test "stepped - oob":
      expect AssertionDefect:
        discard stepped.getIndicies(3)

