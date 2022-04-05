import std/sets
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

proc run(proving: Proving) {.async.} =
  while not proving.stopped:
    for id in proving.contracts:
      if (await proving.timing.isProofRequired(id)) or
         (await proving.timing.willProofBeRequired(id)):
        if callback =? proving.onProofRequired:
          callback(id)
    await proving.timing.waitUntilNextPeriod()

proc start*(proving: Proving) =
  asyncSpawn proving.run()

proc stop*(proving: Proving) =
  proving.stopped = true
