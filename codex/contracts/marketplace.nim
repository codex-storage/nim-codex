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

  Marketplace_RepairRewardPercentageTooHigh* = object of SolidityError
  Marketplace_SlashPercentageTooHigh* = object of SolidityError
  Marketplace_MaximumSlashingTooHigh* = object of SolidityError
  Marketplace_InvalidExpiry* = object of SolidityError
  Marketplace_InvalidMaxSlotLoss* = object of SolidityError
  Marketplace_InsufficientSlots* = object of SolidityError
  Marketplace_InvalidClientAddress* = object of SolidityError
  Marketplace_RequestAlreadyExists* = object of SolidityError
  Marketplace_InvalidSlot* = object of SolidityError
  Marketplace_SlotNotFree* = object of SolidityError
  Marketplace_InvalidSlotHost* = object of SolidityError
  Marketplace_AlreadyPaid* = object of SolidityError
  Marketplace_TransferFailed* = object of SolidityError
  Marketplace_UnknownRequest* = object of SolidityError
  Marketplace_InvalidState* = object of SolidityError
  Marketplace_StartNotBeforeExpiry* = object of SolidityError
  Marketplace_SlotNotAcceptingProofs* = object of SolidityError
  Marketplace_SlotIsFree* = object of SolidityError
  Marketplace_ReservationRequired* = object of SolidityError
  Marketplace_NothingToWithdraw* = object of SolidityError
  Marketplace_InsufficientDuration* = object of SolidityError
  Marketplace_InsufficientProofProbability* = object of SolidityError
  Marketplace_InsufficientCollateral* = object of SolidityError
  Marketplace_InsufficientReward* = object of SolidityError
  Marketplace_InvalidCid* = object of SolidityError
  Marketplace_DurationExceedsLimit* = object of SolidityError
  Proofs_InsufficientBlockHeight* = object of SolidityError
  Proofs_InvalidProof* = object of SolidityError
  Proofs_ProofAlreadySubmitted* = object of SolidityError
  Proofs_PeriodNotEnded* = object of SolidityError
  Proofs_ValidationTimedOut* = object of SolidityError
  Proofs_ProofNotMissing* = object of SolidityError
  Proofs_ProofNotRequired* = object of SolidityError
  Proofs_ProofAlreadyMarkedMissing* = object of SolidityError
  Periods_InvalidSecondsPerPeriod* = object of SolidityError
  SlotReservations_ReservationNotAllowed* = object of SolidityError

proc configuration*(marketplace: Marketplace): MarketplaceConfig {.contract, view.}
proc token*(marketplace: Marketplace): Address {.contract, view.}
proc currentCollateral*(
  marketplace: Marketplace, id: SlotId
): UInt256 {.contract, view.}

proc requestStorage*(
  marketplace: Marketplace, request: StorageRequest
): Confirmable {.
  contract,
  errors: [
    Marketplace_InvalidClientAddress, Marketplace_RequestAlreadyExists,
    Marketplace_InvalidExpiry, Marketplace_InsufficientSlots,
    Marketplace_InvalidMaxSlotLoss, Marketplace_InsufficientDuration,
    Marketplace_InsufficientProofProbability, Marketplace_InsufficientCollateral,
    Marketplace_InsufficientReward, Marketplace_InvalidCid,
  ]
.}

proc fillSlot*(
  marketplace: Marketplace, requestId: RequestId, slotIndex: uint64, proof: Groth16Proof
): Confirmable {.
  contract,
  errors: [
    Marketplace_InvalidSlot, Marketplace_ReservationRequired, Marketplace_SlotNotFree,
    Marketplace_StartNotBeforeExpiry, Marketplace_UnknownRequest,
  ]
.}

proc withdrawFunds*(
  marketplace: Marketplace, requestId: RequestId
): Confirmable {.
  contract,
  errors: [
    Marketplace_InvalidClientAddress, Marketplace_InvalidState,
    Marketplace_NothingToWithdraw, Marketplace_UnknownRequest,
  ]
.}

proc withdrawFunds*(
  marketplace: Marketplace, requestId: RequestId, withdrawAddress: Address
): Confirmable {.
  contract,
  errors: [
    Marketplace_InvalidClientAddress, Marketplace_InvalidState,
    Marketplace_NothingToWithdraw, Marketplace_UnknownRequest,
  ]
.}

proc freeSlot*(
  marketplace: Marketplace, id: SlotId
): Confirmable {.
  contract,
  errors: [
    Marketplace_InvalidSlotHost, Marketplace_AlreadyPaid,
    Marketplace_StartNotBeforeExpiry, Marketplace_UnknownRequest, Marketplace_SlotIsFree,
  ]
.}

proc freeSlot*(
  marketplace: Marketplace,
  id: SlotId,
  rewardRecipient: Address,
  collateralRecipient: Address,
): Confirmable {.
  contract,
  errors: [
    Marketplace_InvalidSlotHost, Marketplace_AlreadyPaid,
    Marketplace_StartNotBeforeExpiry, Marketplace_UnknownRequest, Marketplace_SlotIsFree,
  ]
.}

proc getRequest*(
  marketplace: Marketplace, id: RequestId
): StorageRequest {.contract, view, errors: [Marketplace_UnknownRequest].}

proc getHost*(marketplace: Marketplace, id: SlotId): Address {.contract, view.}
proc getActiveSlot*(
  marketplace: Marketplace, id: SlotId
): Slot {.contract, view, errors: [Marketplace_SlotIsFree].}

proc myRequests*(marketplace: Marketplace): seq[RequestId] {.contract, view.}
proc mySlots*(marketplace: Marketplace): seq[SlotId] {.contract, view.}
proc requestState*(
  marketplace: Marketplace, requestId: RequestId
): RequestState {.contract, view, errors: [Marketplace_UnknownRequest].}

proc slotState*(marketplace: Marketplace, slotId: SlotId): SlotState {.contract, view.}
proc requestEnd*(
  marketplace: Marketplace, requestId: RequestId
): SecondsSince1970 {.contract, view.}

proc requestExpiry*(
  marketplace: Marketplace, requestId: RequestId
): SecondsSince1970 {.contract, view.}

proc missingProofs*(marketplace: Marketplace, id: SlotId): UInt256 {.contract, view.}
proc isProofRequired*(marketplace: Marketplace, id: SlotId): bool {.contract, view.}
proc willProofBeRequired*(marketplace: Marketplace, id: SlotId): bool {.contract, view.}
proc getChallenge*(
  marketplace: Marketplace, id: SlotId
): array[32, byte] {.contract, view.}

proc getPointer*(marketplace: Marketplace, id: SlotId): uint8 {.contract, view.}

proc submitProof*(
  marketplace: Marketplace, id: SlotId, proof: Groth16Proof
): Confirmable {.
  contract,
  errors:
    [Proofs_ProofAlreadySubmitted, Proofs_InvalidProof, Marketplace_UnknownRequest]
.}

proc markProofAsMissing*(
  marketplace: Marketplace, id: SlotId, period: uint64
): Confirmable {.
  contract,
  errors: [
    Marketplace_SlotNotAcceptingProofs, Marketplace_StartNotBeforeExpiry,
    Proofs_PeriodNotEnded, Proofs_ValidationTimedOut, Proofs_ProofNotMissing,
    Proofs_ProofNotRequired, Proofs_ProofAlreadyMarkedMissing,
  ]
.}

proc canMarkProofAsMissing*(
  marketplace: Marketplace, id: SlotId, period: uint64
): Confirmable {.
  contract,
  errors: [
    Marketplace_SlotNotAcceptingProofs, Proofs_PeriodNotEnded,
    Proofs_ValidationTimedOut, Proofs_ProofNotMissing, Proofs_ProofNotRequired,
    Proofs_ProofAlreadyMarkedMissing,
  ]
.}

proc reserveSlot*(
  marketplace: Marketplace, requestId: RequestId, slotIndex: uint64
): Confirmable {.contract.}

proc canReserveSlot*(
  marketplace: Marketplace, requestId: RequestId, slotIndex: uint64
): bool {.contract, view.}
