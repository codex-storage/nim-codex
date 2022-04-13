import pkg/ethers
import ../por/timing/proofs
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

method getCurrentPeriod*(proofs: OnChainProofs): Future[Period] {.async.} =
  let periodicity = await proofs.periodicity()
  let blk = !await proofs.storage.provider.getBlock(BlockTag.latest)
  return periodicity.periodOf(blk.timestamp)

method waitUntilPeriod*(proofs: OnChainProofs,
                        period: Period) {.async.} =
  while (await proofs.getCurrentPeriod()) < period:
    await sleepAsync(proofs.pollInterval)

method isProofRequired*(proofs: OnChainProofs,
                        id: ContractId): Future[bool] {.async.} =
  return await proofs.storage.isProofRequired(id)

method willProofBeRequired*(proofs: OnChainProofs,
                            id: ContractId): Future[bool] {.async.} =
  return await proofs.storage.willProofBeRequired(id)

method getProofEnd*(proofs: OnChainProofs,
                    id: ContractId): Future[UInt256] {.async.} =
  return await proofs.storage.proofEnd(id)

method submitProof*(proofs: OnChainProofs,
                    id: ContractId,
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
