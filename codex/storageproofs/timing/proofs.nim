import pkg/chronos
import pkg/stint
import pkg/questionable
import pkg/upraises
import ./periods
import ../../contracts/requests

export chronos
export stint
export periods
export requests

type
  Proofs* = ref object of RootObj
  Subscription* = ref object of RootObj
  OnProofSubmitted* = proc(id: SlotId, proof: seq[byte]) {.gcsafe, upraises:[].}

method periodicity*(proofs: Proofs):
                   Future[Periodicity] {.base, async.} =
  raiseAssert("not implemented")

method isProofRequired*(proofs: Proofs,
                        id: SlotId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method willProofBeRequired*(proofs: Proofs,
                            id: SlotId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method slotState*(proofs: Proofs,
                  id: SlotId): Future[SlotState] {.base, async.} =
  raiseAssert("not implemented")

method submitProof*(proofs: Proofs,
                    id: SlotId,
                    proof: seq[byte]) {.base, async.} =
  raiseAssert("not implemented")

method subscribeProofSubmission*(proofs: Proofs,
                                 callback: OnProofSubmitted):
                                Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method unsubscribe*(subscription: Subscription) {.base, async, upraises:[].} =
  raiseAssert("not implemented")
