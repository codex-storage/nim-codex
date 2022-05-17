import std/sets
import std/times
import pkg/upraises
import pkg/questionable
import pkg/chronicles
import ./por/timing/proofs

export sets
export proofs

type
  Proving* = ref object
    proofs: Proofs
    loop: ?Future[void]
    contracts*: HashSet[ContractId]
    onProofRequired: ?OnProofRequired
  OnProofRequired* = proc (id: ContractId) {.gcsafe, upraises:[].}

func new*(_: type Proving, proofs: Proofs): Proving =
  Proving(proofs: proofs)

proc `onProofRequired=`*(proving: Proving, callback: OnProofRequired) =
  proving.onProofRequired = some callback

func add*(proving: Proving, id: ContractId) =
  proving.contracts.incl(id)

proc removeEndedContracts(proving: Proving) {.async.} =
  let now = getTime().toUnix().u256
  var ended: HashSet[ContractId]
  for id in proving.contracts:
    if now >= (await proving.proofs.getProofEnd(id)):
      ended.incl(id)
  proving.contracts.excl(ended)

proc run(proving: Proving) {.async.} =
  try:
    while true:
      let currentPeriod = await proving.proofs.getCurrentPeriod()
      await proving.removeEndedContracts()
      for id in proving.contracts:
        if (await proving.proofs.isProofRequired(id)) or
          (await proving.proofs.willProofBeRequired(id)):
          if callback =? proving.onProofRequired:
            callback(id)
      await proving.proofs.waitUntilPeriod(currentPeriod + 1)
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
