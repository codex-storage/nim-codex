import std/sets
import std/times
import pkg/upraises
import pkg/questionable
import ./por/timing/prooftiming

export sets
export prooftiming

type
  Proving* = ref object
    timing: ProofTiming
    stopped: bool
    contracts*: HashSet[ContractId]
    onProofRequired: ?OnProofRequired
  OnProofRequired* = proc (id: ContractId) {.gcsafe, upraises:[].}

func new*(_: type Proving, timing: ProofTiming): Proving =
  Proving(timing: timing)

proc `onProofRequired=`*(proving: Proving, callback: OnProofRequired) =
  proving.onProofRequired = some callback

func add*(proving: Proving, id: ContractId) =
  proving.contracts.incl(id)

proc removeEndedContracts(proving: Proving) {.async.} =
  let now = getTime().toUnix().u256
  var ended: HashSet[ContractId]
  for id in proving.contracts:
    if now >= (await proving.timing.getProofEnd(id)):
      ended.incl(id)
  proving.contracts.excl(ended)

proc run(proving: Proving) {.async.} =
  while not proving.stopped:
    let currentPeriod = await proving.timing.getCurrentPeriod()
    await proving.removeEndedContracts()
    for id in proving.contracts:
      if (await proving.timing.isProofRequired(id)) or
         (await proving.timing.willProofBeRequired(id)):
        if callback =? proving.onProofRequired:
          callback(id)
    await proving.timing.waitUntilPeriod(currentPeriod + 1)

proc start*(proving: Proving) =
  asyncSpawn proving.run()

proc stop*(proving: Proving) =
  proving.stopped = true
