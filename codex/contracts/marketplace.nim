import pkg/ethers
import pkg/ethers/erc20
import pkg/json_rpc/rpcclient
import pkg/stint
import pkg/chronos
import ../clock
import ./requests
import ./proofs
import ./config

export stint
export ethers except `%`, `%*`, toJson
export erc20 except `%`, `%*`, toJson
export config
export requests

type
  Marketplace* = ref object of Contract
  StorageRequested* = object of Event
    requestId*: RequestId
    ask*: StorageAsk
    expiry*: UInt256
  SlotFilled* = object of Event
    requestId* {.indexed.}: RequestId
    slotIndex*: UInt256
  SlotFreed* = object of Event
    requestId* {.indexed.}: RequestId
    slotIndex*: UInt256
  RequestFulfilled* = object of Event
    requestId* {.indexed.}: RequestId
  RequestCancelled* = object of Event
    requestId* {.indexed.}: RequestId
  RequestFailed* = object of Event
    requestId* {.indexed.}: RequestId
  ProofSubmitted* = object of Event
    id*: SlotId


proc config*(marketplace: Marketplace): MarketplaceConfig {.contract, view.}
proc token*(marketplace: Marketplace): Address {.contract, view.}
proc slashMisses*(marketplace: Marketplace): UInt256 {.contract, view.}
proc slashPercentage*(marketplace: Marketplace): UInt256 {.contract, view.}
proc minCollateralThreshold*(marketplace: Marketplace): UInt256 {.contract, view.}

proc requestStorage*(marketplace: Marketplace, request: StorageRequest) {.contract.}
proc fillSlot*(marketplace: Marketplace, requestId: RequestId, slotIndex: UInt256, proof: Groth16Proof) {.contract.}
proc withdrawFunds*(marketplace: Marketplace, requestId: RequestId) {.contract.}
proc freeSlot*(marketplace: Marketplace, id: SlotId) {.contract.}
proc getRequest*(marketplace: Marketplace, id: RequestId): StorageRequest {.contract, view.}
proc getHost*(marketplace: Marketplace, id: SlotId): Address {.contract, view.}
proc getActiveSlot*(marketplace: Marketplace, id: SlotId): Slot {.contract, view.}

proc myRequests*(marketplace: Marketplace): seq[RequestId] {.contract, view.}
proc mySlots*(marketplace: Marketplace): seq[SlotId] {.contract, view.}
proc requestState*(marketplace: Marketplace, requestId: RequestId): RequestState {.contract, view.}
proc slotState*(marketplace: Marketplace, slotId: SlotId): SlotState {.contract, view.}
proc requestEnd*(marketplace: Marketplace, requestId: RequestId): SecondsSince1970 {.contract, view.}

proc proofTimeout*(marketplace: Marketplace): UInt256 {.contract, view.}

proc proofEnd*(marketplace: Marketplace, id: SlotId): UInt256 {.contract, view.}
proc missingProofs*(marketplace: Marketplace, id: SlotId): UInt256 {.contract, view.}
proc isProofRequired*(marketplace: Marketplace, id: SlotId): bool {.contract, view.}
proc willProofBeRequired*(marketplace: Marketplace, id: SlotId): bool {.contract, view.}
proc getChallenge*(marketplace: Marketplace, id: SlotId): array[32, byte] {.contract, view.}
proc getPointer*(marketplace: Marketplace, id: SlotId): uint8 {.contract, view.}

proc submitProof*(marketplace: Marketplace, id: SlotId, proof: Groth16Proof) {.contract.}
proc markProofAsMissing*(marketplace: Marketplace, id: SlotId, period: UInt256) {.contract.}
