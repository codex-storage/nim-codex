import ./errors
import ./utils
import ./utils/asynciter

{.push raises: [].}

type
  StrategyType* = enum
    # Simplest approach:
    # 0 => 0, 1, 2
    # 1 => 3, 4, 5
    # 2 => 6, 7, 8
    LinearStrategy

    # Stepped indexing:
    # 0 => 0, 3, 6
    # 1 => 1, 4, 7
    # 2 => 2, 5, 8
    SteppedStrategy

  # Representing a strategy for grouping indices (of blocks usually)
  # Given an interation-count as input, will produce a seq of
  # selected indices.
  IndexingError* = object of CodexError
  IndexingWrongIndexError* = object of IndexingError
  IndexingWrongIterationsError* = object of IndexingError
  IndexingWrongTotalGroupsError* = object of IndexingError
  IndexingWrongNumPadGroupBlocksError* = object of IndexingError

  IndexingStrategy* = object
    strategyType*: StrategyType # Strategy algorithm
    firstIndex*: int # Lowest index that can be returned
    lastIndex*: int # Highest index that can be returned
    iterations*: int # Number of iterations (0 ..< iterations)
    step*: int # Step size between indices
    totalGroups*: int # Total number of groups to distribute indices into
    numPadGroupBlocks*: int # Optional number of padding blocks per group

func checkIteration(
    self: IndexingStrategy, iteration: int
): void {.raises: [IndexingError].} =
  if iteration >= self.iterations:
    raise newException(
      IndexingError, "Indexing iteration can't be greater than or equal to iterations."
    )

func getIter(first, last, step: int): Iter[int] =
  {.cast(noSideEffect).}:
    Iter[int].new(first, last, step)

func getLinearIndices(
    self: IndexingStrategy, iteration: int
): Iter[int] {.raises: [IndexingError].} =
  self.checkIteration(iteration)

  let
    first = self.firstIndex + iteration * self.step
    last = min(first + self.step - 1, self.lastIndex)

  getIter(first, last, 1)

func getSteppedIndices(
    self: IndexingStrategy, iteration: int
): Iter[int] {.raises: [IndexingError].} =
  self.checkIteration(iteration)

  let
    first = self.firstIndex + iteration
    last = self.lastIndex

  getIter(first, last, self.iterations)

func getIndices*(
    self: IndexingStrategy, iteration: int
): Iter[int] {.raises: [IndexingError].} =
  ## defines the layout of blocks per encoding iteration (data + parity)
  ##

  case self.strategyType
  of StrategyType.LinearStrategy:
    self.getLinearIndices(iteration)
  of StrategyType.SteppedStrategy:
    self.getSteppedIndices(iteration)

func getGroupIndices*(
    self: IndexingStrategy, groupIndex: int
): Iter[int] {.raises: [IndexingError].} =
  ## defines failure recovery groups by selecting specific block indices
  ## from each encoding step (using getIndices)
  ##

  {.cast(noSideEffect).}:
    Iter[int].new(
      iterator (): int {.raises: [IndexingError], gcsafe.} =
        var idx = groupIndex
        for step in 0 ..< self.iterations:
          var
            current = 0
            found = false
          for value in self.getIndices(step):
            if current == idx:
              yield value
              found = true
              break
            inc current
          if not found:
            raise newException(
              IndexingError, "groupIndex exceeds indices length in iteration " & $step
            )
          idx = (idx + 1) mod self.totalGroups

        for i in 0 ..< self.numPadGroupBlocks:
          yield self.lastIndex + (groupIndex + 1) + i * self.totalGroups

    )

func init*(
    strategy: StrategyType,
    firstIndex, lastIndex, iterations, totalGroups: int,
    numPadGroupBlocks = 0.int,
): IndexingStrategy {.raises: [IndexingError].} =
  if firstIndex > lastIndex:
    raise newException(
      IndexingWrongIndexError,
      "firstIndex (" & $firstIndex & ") can't be greater than lastIndex (" & $lastIndex &
        ")",
    )

  if iterations <= 0:
    raise newException(
      IndexingWrongIterationsError,
      "iterations (" & $iterations & ") must be greater than zero.",
    )

  if totalGroups <= 0:
    raise newException(
      IndexingWrongTotalGroupsError,
      "totalGroups (" & $totalGroups & ") must be greater than zero.",
    )

  if numPadGroupBlocks < 0:
    raise newException(
      IndexingWrongNumPadGroupBlocksError,
      "numPadGroupBlocks (" & $numPadGroupBlocks &
        ") must be equal or greater than zero.",
    )

  IndexingStrategy(
    strategyType: strategy,
    firstIndex: firstIndex,
    lastIndex: lastIndex,
    iterations: iterations,
    totalGroups: totalGroups,
    step: divUp((lastIndex - firstIndex + 1), iterations),
    numPadGroupBlocks: numPadGroupBlocks,
  )
