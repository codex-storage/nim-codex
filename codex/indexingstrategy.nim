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
  IndexingWrongGroupCountError* = object of IndexingError
  IndexingWrongPadBlockCountError* = object of IndexingError

  IndexingStrategy* = object
    strategyType*: StrategyType # Indexing strategy algorithm
    firstIndex*: int # Lowest index that can be returned
    lastIndex*: int # Highest index that can be returned
    iterations*: int # Number of iteration steps (0 ..< iterations)
    step*: int # Step size between generated indices
    groupCount*: int # Number of groups to partition indices into
    padBlockCount*: int # Number of padding blocks to append per group

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

func getLinearIndicies(self: IndexingStrategy, iteration: int): Iter[int] =
  let
    first = self.firstIndex + iteration * self.step
    last = min(first + self.step - 1, self.lastIndex)

  getIter(first, last, 1)

func getSteppedIndicies(self: IndexingStrategy, iteration: int): Iter[int] =
  let
    first = self.firstIndex + iteration
    last = self.lastIndex

  getIter(first, last, self.iterations)

func getStrategyIndicies(self: IndexingStrategy, iteration: int): Iter[int] =
  case self.strategyType
  of StrategyType.LinearStrategy:
    self.getLinearIndicies(iteration)
  of StrategyType.SteppedStrategy:
    self.getSteppedIndicies(iteration)

func getIndicies*(
    self: IndexingStrategy, iteration: int
): Iter[int] {.raises: [IndexingError].} =
  self.checkIteration(iteration)
  {.cast(noSideEffect).}:
    Iter[int].new(
      iterator (): int {.gcsafe.} =
        for value in self.getStrategyIndicies(iteration):
          yield value

        for i in 0 ..< self.padBlockCount:
          yield self.lastIndex + (iteration + 1) + i * self.groupCount

    )

func init*(
    strategy: StrategyType,
    firstIndex, lastIndex, iterations: int,
    groupCount = 0,
    padBlockCount = 0,
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

  if padBlockCount < 0:
    raise newException(
      IndexingWrongPadBlockCountError,
      "padBlockCount (" & $padBlockCount & ") must be equal or greater than zero.",
    )

  if padBlockCount > 0 and groupCount <= 0:
    raise newException(
      IndexingWrongGroupCountError,
      "groupCount (" & $groupCount & ") must be greater than zero.",
    )

  IndexingStrategy(
    strategyType: strategy,
    firstIndex: firstIndex,
    lastIndex: lastIndex,
    iterations: iterations,
    step: divUp((lastIndex - firstIndex + 1), iterations),
    groupCount: groupCount,
    padBlockCount: padBlockCount,
  )
