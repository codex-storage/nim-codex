import std/sets
import std/tables
import pkg/dagger/por/timing/prooftiming

type
  MockProofTiming* = ref object of ProofTiming
    periodicity: Periodicity
    currentPeriod: Period
    waiting: Table[Period, seq[Future[void]]]
    proofsRequired: HashSet[ContractId]
    proofsToBeRequired: HashSet[ContractId]
    proofEnds: Table[ContractId, UInt256]

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

proc setProofEnd*(mock: MockProofTiming, id: ContractId, proofEnd: UInt256) =
  mock.proofEnds[id] = proofEnd

method getProofEnd*(mock: MockProofTiming,
                    id: ContractId): Future[UInt256] {.async.} =
  if mock.proofEnds.hasKey(id):
    return mock.proofEnds[id]
  else:
    return UInt256.high

proc advanceToPeriod*(mock: MockProofTiming, period: Period) =
  doAssert period >= mock.currentPeriod
  for key in mock.waiting.keys:
    if key <= period:
      for future in mock.waiting[key]:
        future.complete()
      mock.waiting[key] = @[]

method getCurrentPeriod*(mock: MockProofTiming): Future[Period] {.async.} =
  return mock.currentPeriod

method waitUntilPeriod*(mock: MockProofTiming, period: Period) {.async.} =
  if period > mock.currentPeriod:
    let future = Future[void]()
    if not mock.waiting.hasKey(period):
      mock.waiting[period] = @[]
    mock.waiting[period].add(future)
    await future
