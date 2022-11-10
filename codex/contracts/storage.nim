import pkg/ethers
import pkg/json_rpc/rpcclient
import pkg/stint
import pkg/chronos
import ../clock
import ./requests

export stint
export ethers

type
  Storage* = ref object of Contract
  StorageRequested* = object of Event
    requestId*: RequestId
    ask*: StorageAsk
  SlotFilled* = object of Event
    requestId* {.indexed.}: RequestId
    slotIndex* {.indexed.}: UInt256
    slotId*: SlotId
  RequestFulfilled* = object of Event
    requestId* {.indexed.}: RequestId
  RequestCancelled* = object of Event
    requestId* {.indexed.}: RequestId
  RequestFailed* = object of Event
    requestId* {.indexed.}: RequestId
  ProofSubmitted* = object of Event
    id*: SlotId
    proof*: seq[byte]


proc collateralAmount*(storage: Storage): UInt256 {.contract, view.}
proc slashMisses*(storage: Storage): UInt256 {.contract, view.}
proc slashPercentage*(storage: Storage): UInt256 {.contract, view.}
proc minCollateralThreshold*(storage: Storage): UInt256 {.contract, view.}

proc deposit*(storage: Storage, amount: UInt256) {.contract.}
proc withdraw*(storage: Storage) {.contract.}
proc balanceOf*(storage: Storage, account: Address): UInt256 {.contract, view.}

proc requestStorage*(storage: Storage, request: StorageRequest) {.contract.}
proc fillSlot*(storage: Storage, requestId: RequestId, slotIndex: UInt256, proof: seq[byte]) {.contract.}
proc withdrawFunds*(storage: Storage, requestId: RequestId) {.contract.}
proc payoutSlot*(storage: Storage, requestId: RequestId, slotIndex: UInt256) {.contract.}
proc getRequest*(storage: Storage, id: RequestId): StorageRequest {.contract, view.}
proc getHost*(storage: Storage, id: SlotId): Address {.contract, view.}
proc getSlot*(storage: Storage, id: SlotId): Slot {.contract, view.}

proc myRequests*(storage: Storage): seq[RequestId] {.contract, view.}
proc mySlots*(storage: Storage): seq[SlotId] {.contract, view.}
proc state*(storage: Storage, requestId: RequestId): RequestState {.contract, view.}
proc requestEnd*(storage: Storage, requestId: RequestId): SecondsSince1970 {.contract, view.}

proc proofPeriod*(storage: Storage): UInt256 {.contract, view.}
proc proofTimeout*(storage: Storage): UInt256 {.contract, view.}

proc proofEnd*(storage: Storage, id: SlotId): UInt256 {.contract, view.}
proc missingProofs*(storage: Storage, id: SlotId): UInt256 {.contract, view.}
proc isProofRequired*(storage: Storage, id: SlotId): bool {.contract, view.}
proc willProofBeRequired*(storage: Storage, id: SlotId): bool {.contract, view.}
proc getChallenge*(storage: Storage, id: SlotId): array[32, byte] {.contract, view.}
proc getPointer*(storage: Storage, id: SlotId): uint8 {.contract, view.}

proc submitProof*(storage: Storage, id: SlotId, proof: seq[byte]) {.contract.}
proc markProofAsMissing*(storage: Storage, id: SlotId, period: UInt256) {.contract.}
