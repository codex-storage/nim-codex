import pkg/dagger/por/timing/prooftiming

type
  MockProofTiming* = ref object of ProofTiming
    periodicity: Periodicity
    waiting: seq[Future[void]]
    isProofRequired: bool

const DefaultPeriodLength = 10.u256

func new*(_: type MockProofTiming): MockProofTiming =
  MockProofTiming(periodicity: Periodicity(seconds: DefaultPeriodLength))

func setPeriodicity*(mock: MockProofTiming, periodicity: Periodicity) =
  mock.periodicity = periodicity

method periodicity*(mock: MockProofTiming): Future[Periodicity] {.async.} =
  return mock.periodicity

proc setProofRequired*(mock: MockProofTiming, isProofRequired: bool) =
  mock.isProofRequired = isProofRequired

method isProofRequired*(mock: MockProofTiming): Future[bool] {.async.} =
  return mock.isProofRequired

proc advanceToNextPeriod*(mock: MockProofTiming) =
  for future in mock.waiting:
    future.complete()
  mock.waiting = @[]

method waitUntilNextPeriod*(mock: MockProofTiming) {.async.} =
  let future = Future[void]()
  mock.waiting.add(future)
  await future
