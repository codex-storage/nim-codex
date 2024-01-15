import std/sequtils

import ./errors
import ./utils
import ./utils/asynciter

{.push raises: [].}

type
  # Representing a strategy for grouping indices (of blocks usually)
  # Given an interation-count as input, will produce a seq of
  # selected indices.

  IndexingError* = object of CodexError
  IndexingWrongIndexError* = object of IndexingError
  IndexingWrongIterationsError* = object of IndexingError

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

proc checkIteration(
  self: IndexingStrategy,
  iteration: int): void {.raises: [IndexingError].} =
  if iteration >= self.numberOfIterations:
    raise newException(
      IndexingError,
      "Indexing iteration can't be greater than or equal to numberOfIterations.")

method getIndicies*(
  self: IndexingStrategy,
  iteration: int): Iter[int] {.base, raises: [IndexingError].} =
  raiseAssert("Not implemented")

proc getIter(first, last, step: int): Iter[int] =
  var
    finish = false
    cur = first
  proc get(): int =
    result = cur
    cur += step

    if cur > last:
      finish = true

  proc isFinished(): bool =
    finish

  Iter.new(get, isFinished)

method getIndicies*(
  self: LinearIndexingStrategy,
  iteration: int): Iter[int] {.raises: [IndexingError].} =

  self.checkIteration(iteration)

  let
    first = self.firstIndex + iteration * (self.step + 1)
    last = min(first + self.step, self.lastIndex)

  getIter(first, last, 1)

method getIndicies*(
  self: SteppedIndexingStrategy,
  iteration: int): Iter[int] {.raises: [IndexingError].} =

  self.checkIteration(iteration)

  let
    first = self.firstIndex + iteration
    last = self.lastIndex

  getIter(first, last, self.numberOfIterations)

proc new*(
  T: type IndexingStrategy,
  firstIndex, lastIndex, numberOfIterations: int): T {.raises: [IndexingError].} =
  if firstIndex > lastIndex:
    raise newException(
      IndexingWrongIndexError,
      "firstIndex (" & $firstIndex & ") can't be greater than lastIndex (" & $lastIndex & ")")

  if numberOfIterations <= 0:
    raise newException(
      IndexingWrongIterationsError,
      "numberOfIteration (" & $numberOfIterations & ") must be greater than zero.")

  T(
    firstIndex: firstIndex,
    lastIndex: lastIndex,
    numberOfIterations: numberOfIterations,
    step: divUp((lastIndex - firstIndex), numberOfIterations)
  )
