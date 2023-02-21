import std/sets
import pkg/upraises
import pkg/questionable
import pkg/chronicles
import ./storageproofs
import ./clock

export sets
export storageproofs

type
  Proving* = ref object
    proofs: Proofs
    clock: Clock
    loop: ?Future[void]
    slots*: HashSet[SlotId]
    onProofRequired: ?OnProofRequired
  OnProofRequired* = proc (id: SlotId) {.gcsafe, upraises:[].}

func new*(_: type Proving, proofs: Proofs, clock: Clock): Proving =
  Proving(proofs: proofs, clock: clock)

proc `onProofRequired=`*(proving: Proving, callback: OnProofRequired) =
  proving.onProofRequired = some callback

func add*(proving: Proving, id: SlotId) =
  proving.slots.incl(id)

proc getCurrentPeriod(proving: Proving): Future[Period] {.async.} =
  let periodicity = await proving.proofs.periodicity()
  return periodicity.periodOf(proving.clock.now().u256)

proc waitUntilPeriod(proving: Proving, period: Period) {.async.} =
  let periodicity = await proving.proofs.periodicity()
  await proving.clock.waitUntil(periodicity.periodStart(period).truncate(int64))

proc removeEndedContracts(proving: Proving) {.async.} =
  let now = proving.clock.now().u256
  var ended: HashSet[SlotId]
  for id in proving.slots:
    let state = await proving.proofs.slotState(id)
    if state != SlotState.Filled:
      ended.incl(id)
  proving.slots.excl(ended)

proc run(proving: Proving) {.async.} =
  try:
    while true:
      let currentPeriod = await proving.getCurrentPeriod()
      await proving.removeEndedContracts()
      for id in proving.slots:
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

proc submitProof*(proving: Proving, id: SlotId, proof: seq[byte]) {.async.} =
  await proving.proofs.submitProof(id, proof)

proc subscribeProofSubmission*(proving: Proving,
                               callback: OnProofSubmitted):
                              Future[Subscription] =
  proving.proofs.subscribeProofSubmission(callback)
