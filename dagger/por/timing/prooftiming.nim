import pkg/chronos
import pkg/stint
import ./periods

export chronos
export stint
export periods

type
  ProofTiming* = ref object of RootObj
  ContractId* = array[32, byte]

method periodicity*(proofTiming: ProofTiming):
                   Future[Periodicity] {.base, async.} =
  raiseAssert("not implemented")

method waitUntilNextPeriod*(proofTiming: ProofTiming) {.base, async.} =
  raiseAssert("not implemented")

method isProofRequired*(proofTiming: ProofTiming,
                        id: ContractId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method willProofBeRequired*(proofTiming: ProofTiming,
                            id: ContractId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method getProofEnd*(proofTiming: ProofTiming,
                    id: ContractId): Future[UInt256] {.base, async.} =
  raiseAssert("not implemented")
