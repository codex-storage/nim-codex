import pkg/chronos
import pkg/stint
import pkg/upraises
import ./periods

export chronos
export stint
export periods

type
  Proofs* = ref object of RootObj
  Subscription* = ref object of RootObj
  OnProofSubmitted* = proc(id: ContractId, proof: seq[byte]) {.gcsafe, upraises:[].}
  ContractId* = array[32, byte]

method periodicity*(proofs: Proofs):
                   Future[Periodicity] {.base, async.} =
  raiseAssert("not implemented")

method isProofRequired*(proofs: Proofs,
                        id: ContractId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method willProofBeRequired*(proofs: Proofs,
                            id: ContractId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method getProofEnd*(proofs: Proofs,
                    id: ContractId): Future[UInt256] {.base, async.} =
  raiseAssert("not implemented")

method submitProof*(proofs: Proofs,
                    id: ContractId,
                    proof: seq[byte]) {.base, async.} =
  raiseAssert("not implemented")

method subscribeProofSubmission*(proofs: Proofs,
                                 callback: OnProofSubmitted):
                                Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method unsubscribe*(subscription: Subscription) {.base, async, upraises:[].} =
  raiseAssert("not implemented")
