import std/sets
import std/tables
import pkg/dagger/por/timing/proofs

type
  MockProofs* = ref object of Proofs
    periodicity: Periodicity
    currentPeriod: Period
    waiting: Table[Period, seq[Future[void]]]
    proofsRequired: HashSet[ContractId]
    proofsToBeRequired: HashSet[ContractId]
    proofEnds: Table[ContractId, UInt256]

const DefaultPeriodLength = 10.u256

func new*(_: type MockProofs): MockProofs =
  MockProofs(periodicity: Periodicity(seconds: DefaultPeriodLength))

func setPeriodicity*(mock: MockProofs, periodicity: Periodicity) =
  mock.periodicity = periodicity

method periodicity*(mock: MockProofs): Future[Periodicity] {.async.} =
  return mock.periodicity

proc setProofRequired*(mock: MockProofs, id: ContractId, required: bool) =
  if required:
    mock.proofsRequired.incl(id)
  else:
    mock.proofsRequired.excl(id)

method isProofRequired*(mock: MockProofs,
                        id: ContractId): Future[bool] {.async.} =
  return mock.proofsRequired.contains(id)

proc setProofToBeRequired*(mock: MockProofs, id: ContractId, required: bool) =
  if required:
    mock.proofsToBeRequired.incl(id)
  else:
    mock.proofsToBeRequired.excl(id)

method willProofBeRequired*(mock: MockProofs,
                            id: ContractId): Future[bool] {.async.} =
  return mock.proofsToBeRequired.contains(id)

proc setProofEnd*(mock: MockProofs, id: ContractId, proofEnd: UInt256) =
  mock.proofEnds[id] = proofEnd

method getProofEnd*(mock: MockProofs,
                    id: ContractId): Future[UInt256] {.async.} =
  if mock.proofEnds.hasKey(id):
    return mock.proofEnds[id]
  else:
    return UInt256.high

proc advanceToPeriod*(mock: MockProofs, period: Period) =
  doAssert period >= mock.currentPeriod
  for key in mock.waiting.keys:
    if key <= period:
      for future in mock.waiting[key]:
        future.complete()
      mock.waiting[key] = @[]

method getCurrentPeriod*(mock: MockProofs): Future[Period] {.async.} =
  return mock.currentPeriod

method waitUntilPeriod*(mock: MockProofs, period: Period) {.async.} =
  if period > mock.currentPeriod:
    let future = Future[void]()
    if not mock.waiting.hasKey(period):
      mock.waiting[period] = @[]
    mock.waiting[period].add(future)
    await future
