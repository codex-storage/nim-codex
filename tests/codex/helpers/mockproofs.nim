import std/sets
import std/tables
import std/sequtils
import pkg/upraises
import pkg/codex/storageproofs

type
  MockProofs* = ref object of Proofs
    periodicity: Periodicity
    cancelledSlots: HashSet[SlotId]
    proofsRequired: HashSet[SlotId]
    proofsToBeRequired: HashSet[SlotId]
    proofEnds: Table[SlotId, UInt256]
    subscriptions: seq[MockSubscription]
  MockSubscription* = ref object of Subscription
    proofs: MockProofs
    callback: OnProofSubmitted

const DefaultPeriodLength = 10.u256

func new*(_: type MockProofs): MockProofs =
  MockProofs(periodicity: Periodicity(seconds: DefaultPeriodLength))

func setPeriodicity*(mock: MockProofs, periodicity: Periodicity) =
  mock.periodicity = periodicity

method periodicity*(mock: MockProofs): Future[Periodicity] {.async.} =
  return mock.periodicity

proc setProofRequired*(mock: MockProofs, id: SlotId, required: bool) =
  if required:
    mock.proofsRequired.incl(id)
  else:
    mock.proofsRequired.excl(id)

proc setSlotCancelled*(mock: MockProofs, id: SlotId, required: bool) =
  if required:
    mock.cancelledSlots.incl(id)
  else:
    mock.cancelledSlots.excl(id)

method isSlotCancelled*(mock: MockProofs,
                        id: SlotId): Future[bool] {.async.} =
  return mock.cancelledSlots.contains(id)

method isProofRequired*(mock: MockProofs,
                        id: SlotId): Future[bool] {.async.} =
  return mock.proofsRequired.contains(id)

proc setProofToBeRequired*(mock: MockProofs, id: SlotId, required: bool) =
  if required:
    mock.proofsToBeRequired.incl(id)
  else:
    mock.proofsToBeRequired.excl(id)

method willProofBeRequired*(mock: MockProofs,
                            id: SlotId): Future[bool] {.async.} =
  return mock.proofsToBeRequired.contains(id)

proc setProofEnd*(mock: MockProofs, id: SlotId, proofEnd: UInt256) =
  mock.proofEnds[id] = proofEnd

method getProofEnd*(mock: MockProofs,
                    id: SlotId): Future[UInt256] {.async.} =
  if mock.proofEnds.hasKey(id):
    return mock.proofEnds[id]
  else:
    return UInt256.high

method submitProof*(mock: MockProofs,
                    id: SlotId,
                    proof: seq[byte]) {.async.} =
  for subscription in mock.subscriptions:
    subscription.callback(id, proof)

method subscribeProofSubmission*(mock: MockProofs,
                                 callback: OnProofSubmitted):
                                Future[Subscription] {.async.} =
  let subscription = MockSubscription(proofs: mock, callback: callback)
  mock.subscriptions.add(subscription)
  return subscription

method unsubscribe*(subscription: MockSubscription) {.async, upraises:[].} =
  subscription.proofs.subscriptions.keepItIf(it != subscription)
