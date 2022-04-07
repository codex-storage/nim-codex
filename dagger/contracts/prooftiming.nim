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

method getCurrentPeriod*(timing: OnChainProofTiming): Future[Period] {.async.} =
  let periodicity = await timing.periodicity()
  let blk = !await timing.storage.provider.getBlock(BlockTag.latest)
  return periodicity.periodOf(blk.timestamp)

method waitUntilPeriod*(timing: OnChainProofTiming,
                        period: Period) {.async.} =
  while (await timing.getCurrentPeriod()) < period:
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
