import std/sequtils

type
  # Representing a strategy for grouping indices (of blocks usually)
  # Given an interation-count as input, will produce a seq of
  # selected indices.
  IndexingStrategy* = ref object of RootObj
    firstIndex: int             # Lowest index that can be returned
    lastIndex: int              # Highest index that can be returned
    numberOfIterations: int     # getIndices(iteration) will run from 0 ..< numberOfIterations

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
    # I'm choosing to use an assert here because:
    # 1. This is a programmer error and *should not* happen during application runtime.
    # 2. Users don't have to deal with Result types.
    raiseAssert("Indexing iteration can't be greater than or equal to numberOfIterations.")

method getIndicies*(self: IndexingStrategy, iteration: int): seq[int] {.base.} =
  raiseAssert("Not implemented")

proc new*(T: type IndexingStrategy, firstIndex, lastIndex, numberOfIterations: int): T =
  T(
    firstIndex: firstIndex,
    lastIndex: lastIndex,
    numberOfIterations: numberOfIterations
  )

method getIndicies*(self: LinearIndexingStrategy, iteration: int): seq[int] =
  self.assertIteration(iteration)

  let
    first = self.firstIndex + iteration * self.numberOfIterations
    last = min(first + self.numberOfIterations, self.lastIndex)
  toSeq(countup(first, last - 1, 1))

method getIndicies*(self: SteppedIndexingStrategy, iteration: int): seq[int] =
  self.assertIteration(iteration)

  let
    first = self.firstIndex + iteration
    last = first + (self.numberOfIterations * self.numberOfIterations)
  toSeq(countup(first, last - 1, self.numberOfIterations))
