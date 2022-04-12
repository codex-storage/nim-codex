import pkg/chronos
import pkg/stint
import ./periods

export chronos
export stint
export periods

type
  Proofs* = ref object of RootObj
  ContractId* = array[32, byte]

method periodicity*(proofs: Proofs):
                   Future[Periodicity] {.base, async.} =
  raiseAssert("not implemented")

method getCurrentPeriod*(proofs: Proofs):
                        Future[Period] {.base, async.} =
  raiseAssert("not implemented")

method waitUntilPeriod*(proofs: Proofs,
                        period: Period) {.base, async.} =
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
