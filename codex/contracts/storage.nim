import pkg/ethers
import pkg/json_rpc/rpcclient
import pkg/stint
import pkg/chronos
import ./requests
import ./offers

export stint
export ethers

type
  Storage* = ref object of Contract
  Id = array[32, byte]
  StorageRequested* = object of Event
    requestId*: Id
    ask*: StorageAsk
  RequestFulfilled* = object of Event
    requestId* {.indexed.}: Id
  ProofSubmitted* = object of Event
    id*: Id
    proof*: seq[byte]

proc collateralAmount*(storage: Storage): UInt256 {.contract, view.}
proc slashMisses*(storage: Storage): UInt256 {.contract, view.}
proc slashPercentage*(storage: Storage): UInt256 {.contract, view.}

proc deposit*(storage: Storage, amount: UInt256) {.contract.}
proc withdraw*(storage: Storage) {.contract.}
proc balanceOf*(storage: Storage, account: Address): UInt256 {.contract, view.}

proc requestStorage*(storage: Storage, request: StorageRequest) {.contract.}
proc fulfillRequest*(storage: Storage, id: Id, proof: seq[byte]) {.contract.}

proc finishContract*(storage: Storage, id: Id) {.contract.}

proc proofPeriod*(storage: Storage): UInt256 {.contract, view.}
proc proofTimeout*(storage: Storage): UInt256 {.contract, view.}

proc proofEnd*(storage: Storage, id: Id): UInt256 {.contract, view.}
proc missingProofs*(storage: Storage, id: Id): UInt256 {.contract, view.}
proc isProofRequired*(storage: Storage, id: Id): bool {.contract, view.}
proc willProofBeRequired*(storage: Storage, id: Id): bool {.contract, view.}
proc getChallenge*(storage: Storage, id: Id): array[32, byte] {.contract, view.}
proc getPointer*(storage: Storage, id: Id): uint8 {.contract, view.}

proc submitProof*(storage: Storage, id: Id, proof: seq[byte]) {.contract.}
proc markProofAsMissing*(storage: Storage, id: Id, period: UInt256) {.contract.}
