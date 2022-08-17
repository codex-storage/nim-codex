import pkg/ethers
import ../storageproofs/timing/proofs
import ./storage

export proofs

type
  OnChainProofs* = ref object of Proofs
    storage: Storage
    pollInterval*: Duration
  ProofsSubscription = proofs.Subscription
  EventSubscription = ethers.Subscription
  OnChainProofsSubscription = ref object of ProofsSubscription
    eventSubscription: EventSubscription

const DefaultPollInterval = 3.seconds

proc new*(_: type OnChainProofs, storage: Storage): OnChainProofs =
  OnChainProofs(storage: storage, pollInterval: DefaultPollInterval)

method periodicity*(proofs: OnChainProofs): Future[Periodicity] {.async.} =
  let period = await proofs.storage.proofPeriod()
  return Periodicity(seconds: period)

method isSlotCancelled*(proofs: OnChainProofs,
                        id: ContractId): Future[bool] {.async.} =
  return await proofs.storage.isSlotCancelled(id)

method isCancelled*(proofs: OnChainProofs,
                    id: array[32, byte]): Future[bool] {.async.} =
  return await proofs.storage.isCancelled(id)

method isProofRequired*(proofs: OnChainProofs,
                        id: SlotId): Future[bool] {.async.} =
  return await proofs.storage.isProofRequired(id)

method willProofBeRequired*(proofs: OnChainProofs,
                            id: SlotId): Future[bool] {.async.} =
  return await proofs.storage.willProofBeRequired(id)

method getProofEnd*(proofs: OnChainProofs,
                    id: SlotId): Future[UInt256] {.async.} =
  return await proofs.storage.proofEnd(id)

method submitProof*(proofs: OnChainProofs,
                    id: SlotId,
                    proof: seq[byte]) {.async.} =
  await proofs.storage.submitProof(id, proof)

method subscribeProofSubmission*(proofs: OnChainProofs,
                                 callback: OnProofSubmitted):
                                Future[ProofsSubscription] {.async.} =
  proc onEvent(event: ProofSubmitted) {.upraises: [].} =
    callback(event.id, event.proof)
  let subscription = await proofs.storage.subscribe(ProofSubmitted, onEvent)
  return OnChainProofsSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainProofsSubscription) {.async, upraises:[].} =
  await subscription.eventSubscription.unsubscribe()
