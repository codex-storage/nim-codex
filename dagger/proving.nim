import std/sets
import std/times
import pkg/upraises
import pkg/questionable
import ./por/timing/proofs

export sets
export proofs

type
  Proving* = ref object
    proofs: Proofs
    stopped: bool
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
  while not proving.stopped:
    let currentPeriod = await proving.proofs.getCurrentPeriod()
    await proving.removeEndedContracts()
    for id in proving.contracts:
      if (await proving.proofs.isProofRequired(id)) or
         (await proving.proofs.willProofBeRequired(id)):
        if callback =? proving.onProofRequired:
          callback(id)
    await proving.proofs.waitUntilPeriod(currentPeriod + 1)

proc start*(proving: Proving) =
  asyncSpawn proving.run()

proc stop*(proving: Proving) =
  proving.stopped = true

proc submitProof*(proving: Proving, id: ContractId, proof: seq[byte]) {.async.} =
  await proving.proofs.submitProof(id, proof)

proc subscribeProofSubmission*(proving: Proving,
                               callback: OnProofSubmitted):
                              Future[Subscription] =
  proving.proofs.subscribeProofSubmission(callback)
