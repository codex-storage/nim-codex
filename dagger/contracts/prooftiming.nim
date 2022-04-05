import ../por/timing/prooftiming
import ./storage

export prooftiming

type
  OnChainProofTiming* = ref object of ProofTiming
    storage: Storage
    pollInterval*: Duration

const DefaultPollInterval = 3.seconds

proc new*(_: type OnChainProofTiming, storage: Storage): OnChainProofTiming =
  OnChainProofTiming(storage: storage, pollInterval: DefaultPollInterval)

method periodicity*(timing: OnChainProofTiming): Future[Periodicity] {.async.} =
  let period = await timing.storage.proofPeriod()
  return Periodicity(seconds: period)

method waitUntilNextPeriod*(timing: OnChainProofTiming) {.async.} =
  let provider = timing.storage.provider
  let periodicity = await timing.periodicity()
  proc getCurrentPeriod: Future[Period] {.async.} =
    let blk = !await provider.getBlock(BlockTag.latest)
    return periodicity.periodOf(blk.timestamp)
  let startPeriod = await getCurrentPeriod()
  while (await getCurrentPeriod()) == startPeriod:
    await sleepAsync(timing.pollInterval)

method isProofRequired*(timing: OnChainProofTiming,
                        id: ContractId): Future[bool] {.async.} =
  return await timing.storage.isProofRequired(id)

method willProofBeRequired*(timing: OnChainProofTiming,
                            id: ContractId): Future[bool] {.async.} =
  return await timing.storage.willProofBeRequired(id)

method getProofEnd*(timing: OnChainProofTiming,
                    id: ContractId): Future[UInt256] {.async.} =
  return await timing.storage.proofEnd(id)
