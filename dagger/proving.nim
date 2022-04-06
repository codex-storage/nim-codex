import std/sets
import pkg/upraises
import pkg/questionable
import ./por/timing/prooftiming

export sets

type
  Proving* = ref object
    timing: ProofTiming
    stopped: bool
    contracts*: HashSet[ContractId]
    onProofRequired: ?OnProofRequired
  ContractId* = array[32, byte]
  OnProofRequired* = proc () {.gcsafe, upraises:[].}

func new*(_: type Proving, timing: ProofTiming): Proving =
  Proving(timing: timing)

proc `onProofRequired=`*(proving: Proving, callback: OnProofRequired) =
  proving.onProofRequired = some callback

func add*(proving: Proving, id: ContractId) =
  proving.contracts.incl(id)

proc run(proving: Proving) {.async.} =
  while not proving.stopped:
    if await proving.timing.isProofRequired():
      if callback =? proving.onProofRequired:
        callback()
    await proving.timing.waitUntilNextPeriod()

proc start*(proving: Proving) =
  asyncSpawn proving.run()

proc stop*(proving: Proving) =
  proving.stopped = true
