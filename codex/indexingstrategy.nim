import std/sequtils
import ./utils

{.push raises: [].}

# I'm choosing to use an assert here because:
# 1. These are a programmer errors and *should not* happen during application runtime.
# 2. Users don't have to deal with Result types.

type
  # Representing a strategy for grouping indices (of blocks usually)
  # Given an interation-count as input, will produce a seq of
  # selected indices.
  IndexingStrategy* = ref object of RootObj
    firstIndex*: int             # Lowest index that can be returned
    lastIndex*: int              # Highest index that can be returned
    numberOfIterations*: int     # getIndices(iteration) will run from 0 ..< numberOfIterations
    step*: int

  # Simplest approach:
  # 0 => 0, 1, 2
  # 1 => 3, 4, 5
  # 2 => 6, 7, 8
  LinearIndexingStrategy* = ref object of IndexingStrategy

  # Stepped indexing:
  # 0 => 0, 3, 6
  # 1 => 1, 4, 7
  # 2 => 2, 5, 8
  SteppedIndexingStrategy* = ref object of IndexingStrategy

proc assertIteration(self: IndexingStrategy, iteration: int): void =
  if iteration >= self.numberOfIterations:
    raiseAssert("Indexing iteration can't be greater than or equal to numberOfIterations.")

method getIndicies*(self: IndexingStrategy, iteration: int): seq[int] {.base.} =
  raiseAssert("Not implemented")

proc new*(T: type IndexingStrategy, firstIndex, lastIndex, numberOfIterations: int): T =
  if firstIndex > lastIndex:
    raiseAssert("firstIndex (" & $firstIndex & ") can't be greater than lastIndex (" & $lastIndex & ")")
  if numberOfIterations <= 0:
    raiseAssert("numberOfIteration (" & $numberOfIterations & ") must be greater than zero.")

  T(
    firstIndex: firstIndex,
    lastIndex: lastIndex,
    numberOfIterations: numberOfIterations,
    step: divUp((lastIndex - firstIndex), numberOfIterations)
  )

method getIndicies*(self: LinearIndexingStrategy, iteration: int): seq[int] =
  self.assertIteration(iteration)

  let
    first = self.firstIndex + iteration * (self.step + 1)
    last = min(first + self.step, self.lastIndex)

  toSeq(countup(first, last, 1))

method getIndicies*(self: SteppedIndexingStrategy, iteration: int): seq[int] =
  self.assertIteration(iteration)
  toSeq(countup(self.firstIndex + iteration, self.lastIndex, self.numberOfIterations))
