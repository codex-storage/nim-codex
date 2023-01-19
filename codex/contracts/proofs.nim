import std/strutils
import pkg/ethers
import pkg/ethers/testing
import ../storageproofs/timing/proofs
import ./marketplace

export proofs

type
  OnChainProofs* = ref object of Proofs
    marketplace: Marketplace
    pollInterval*: Duration
  ProofsSubscription = proofs.Subscription
  EventSubscription = ethers.Subscription
  OnChainProofsSubscription = ref object of ProofsSubscription
    eventSubscription: EventSubscription

const DefaultPollInterval = 3.seconds

proc new*(_: type OnChainProofs, marketplace: Marketplace): OnChainProofs =
  OnChainProofs(marketplace: marketplace, pollInterval: DefaultPollInterval)

method periodicity*(proofs: OnChainProofs): Future[Periodicity] {.async.} =
  let period = await proofs.marketplace.proofPeriod()
  return Periodicity(seconds: period)

method isProofRequired*(proofs: OnChainProofs,
                        id: SlotId): Future[bool] {.async.} =
  try:
    return await proofs.marketplace.isProofRequired(id)
  except ProviderError as e:
    if e.revertReason.contains("Slot empty"):
      return false
    raise e

method willProofBeRequired*(proofs: OnChainProofs,
                            id: SlotId): Future[bool] {.async.} =
  try:
    return await proofs.marketplace.willProofBeRequired(id)
  except ProviderError as e:
    if e.revertReason.contains("Slot empty"):
      return false
    raise e

method getProofEnd*(proofs: OnChainProofs,
                    id: SlotId): Future[UInt256] {.async.} =
  try:
    return await proofs.marketplace.proofEnd(id)
  except ProviderError as e:
    if e.revertReason.contains("Slot empty"):
      return 0.u256
    raise e

method submitProof*(proofs: OnChainProofs,
                    id: SlotId,
                    proof: seq[byte]) {.async.} =
  await proofs.marketplace.submitProof(id, proof)

method subscribeProofSubmission*(proofs: OnChainProofs,
                                 callback: OnProofSubmitted):
                                Future[ProofsSubscription] {.async.} =
  proc onEvent(event: ProofSubmitted) {.upraises: [].} =
    callback(event.id, event.proof)
  let subscription = await proofs.marketplace.subscribe(ProofSubmitted, onEvent)
  return OnChainProofsSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainProofsSubscription) {.async, upraises:[].} =
  await subscription.eventSubscription.unsubscribe()
