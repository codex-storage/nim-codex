import std/sets
import pkg/dagger/por/timing/prooftiming

type
  MockProofTiming* = ref object of ProofTiming
    periodicity: Periodicity
    waiting: seq[Future[void]]
    proofsRequired: HashSet[ContractId]
    proofsToBeRequired: HashSet[ContractId]

const DefaultPeriodLength = 10.u256

func new*(_: type MockProofTiming): MockProofTiming =
  MockProofTiming(periodicity: Periodicity(seconds: DefaultPeriodLength))

func setPeriodicity*(mock: MockProofTiming, periodicity: Periodicity) =
  mock.periodicity = periodicity

method periodicity*(mock: MockProofTiming): Future[Periodicity] {.async.} =
  return mock.periodicity

proc setProofRequired*(mock: MockProofTiming, id: ContractId, required: bool) =
  if required:
    mock.proofsRequired.incl(id)
  else:
    mock.proofsRequired.excl(id)

method isProofRequired*(mock: MockProofTiming,
                        id: ContractId): Future[bool] {.async.} =
  return mock.proofsRequired.contains(id)

proc setProofToBeRequired*(mock: MockProofTiming, id: ContractId, required: bool) =
  if required:
    mock.proofsToBeRequired.incl(id)
  else:
    mock.proofsToBeRequired.excl(id)

method willProofBeRequired*(mock: MockProofTiming,
                            id: ContractId): Future[bool] {.async.} =
  return mock.proofsToBeRequired.contains(id)

proc advanceToNextPeriod*(mock: MockProofTiming) =
  for future in mock.waiting:
    future.complete()
  mock.waiting = @[]

method waitUntilNextPeriod*(mock: MockProofTiming) {.async.} =
  let future = Future[void]()
  mock.waiting.add(future)
  await future
