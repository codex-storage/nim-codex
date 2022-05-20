import std/sets
import pkg/upraises
import pkg/questionable
import pkg/chronicles
import ./storageproofs
import ./clock

export sets
export proofs

type
  Proving* = ref object
    proofs: Proofs
    clock: Clock
    loop: ?Future[void]
    contracts*: HashSet[ContractId]
    onProofRequired: ?OnProofRequired
  OnProofRequired* = proc (id: ContractId) {.gcsafe, upraises:[].}

func new*(_: type Proving, proofs: Proofs, clock: Clock): Proving =
  Proving(proofs: proofs, clock: clock)

proc `onProofRequired=`*(proving: Proving, callback: OnProofRequired) =
  proving.onProofRequired = some callback

func add*(proving: Proving, id: ContractId) =
  proving.contracts.incl(id)

proc getCurrentPeriod(proving: Proving): Future[Period] {.async.} =
  let periodicity = await proving.proofs.periodicity()
  return periodicity.periodOf(proving.clock.now().u256)

proc waitUntilPeriod(proving: Proving, period: Period) {.async.} =
  let periodicity = await proving.proofs.periodicity()
  await proving.clock.waitUntil(periodicity.periodStart(period).truncate(int64))

proc removeEndedContracts(proving: Proving) {.async.} =
  let now = proving.clock.now().u256
  var ended: HashSet[ContractId]
  for id in proving.contracts:
    if now >= (await proving.proofs.getProofEnd(id)):
      ended.incl(id)
  proving.contracts.excl(ended)

proc run(proving: Proving) {.async.} =
  try:
    while true:
      let currentPeriod = await proving.getCurrentPeriod()
      await proving.removeEndedContracts()
      for id in proving.contracts:
        if (await proving.proofs.isProofRequired(id)) or
          (await proving.proofs.willProofBeRequired(id)):
          if callback =? proving.onProofRequired:
            callback(id)
      await proving.waitUntilPeriod(currentPeriod + 1)
  except CancelledError:
    discard
  except CatchableError as e:
    error "Proving failed", msg = e.msg

proc start*(proving: Proving) {.async.} =
  if proving.loop.isSome:
    return

  proving.loop = some proving.run()

proc stop*(proving: Proving) {.async.} =
  if loop =? proving.loop:
    proving.loop = Future[void].none
    if not loop.finished:
      await loop.cancelAndWait()

proc submitProof*(proving: Proving, id: ContractId, proof: seq[byte]) {.async.} =
  await proving.proofs.submitProof(id, proof)

proc subscribeProofSubmission*(proving: Proving,
                               callback: OnProofSubmitted):
                              Future[Subscription] =
  proving.proofs.subscribeProofSubmission(callback)
