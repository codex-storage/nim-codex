import std/sets
import pkg/upraises
import pkg/questionable
import pkg/chronicles
import ./market
import ./clock

export sets

logScope:
    topics = "marketplace proving"

type
  Proving* = ref object
    market: Market
    clock: Clock
    loop: ?Future[void]
    slots*: HashSet[Slot]
    onProve: ?OnProve
  OnProve* = proc(slot: Slot): Future[seq[byte]] {.gcsafe, upraises: [].}

func new*(_: type Proving, market: Market, clock: Clock): Proving =
  Proving(market: market, clock: clock)

proc onProve*(proving: Proving): ?OnProve =
  proving.onProve

proc `onProve=`*(proving: Proving, callback: OnProve) =
  proving.onProve = some callback

func add*(proving: Proving, slot: Slot) =
  proving.slots.incl(slot)

proc getCurrentPeriod(proving: Proving): Future[Period] {.async.} =
  let periodicity = await proving.market.periodicity()
  return periodicity.periodOf(proving.clock.now().u256)

proc waitUntilPeriod(proving: Proving, period: Period) {.async.} =
  let periodicity = await proving.market.periodicity()
  await proving.clock.waitUntil(periodicity.periodStart(period).truncate(int64))

proc removeEndedContracts(proving: Proving) {.async.} =
  var ended: HashSet[Slot]
  for slot in proving.slots:
    let state = await proving.market.slotState(slot.id)
    if state == SlotState.Finished:
      debug "Collecting finished slot's reward", slot = $slot.id
      await proving.market.freeSlot(slot.id)

    if state != SlotState.Filled:
      debug "Request ended, cleaning up slot", slot = $slot.id
      ended.incl(slot)
  proving.slots.excl(ended)

proc prove(proving: Proving, slot: Slot) {.async.} =
  without onProve =? proving.onProve:
    raiseAssert "onProve callback not set"
  try:
    debug "Proving slot"
    let proof = await onProve(slot)
    await proving.market.submitProof(slot.id, proof)
  except CatchableError as e:
    error "Submitting proof failed", msg = e.msg

proc run(proving: Proving) {.async.} =
  try:
    while true:
      let currentPeriod = await proving.getCurrentPeriod()
      debug "Proving for new period", period = currentPeriod
      await proving.removeEndedContracts()
      for slot in proving.slots:
        let id = slot.id
        if (await proving.market.isProofRequired(id)) or
           (await proving.market.willProofBeRequired(id)):
          asyncSpawn proving.prove(slot)
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

proc subscribeProofSubmission*(proving: Proving,
                               callback: OnProofSubmitted):
                              Future[Subscription] =
  proving.market.subscribeProofSubmission(callback)
