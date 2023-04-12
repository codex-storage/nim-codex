import std/sets
import std/tables
import std/sequtils
import pkg/chronos
import pkg/chronicles
import ./market
import ./clock

export market
export sets

type
  Validation* = ref object
    slots: Table[SlotId, ProofRequirements]
    clock: Clock
    market: Market
    subscriptions: seq[Subscription]
    running: Future[void]
    periodicity: Periodicity
    proofTimeout: UInt256
  ProofRequirements = ref object
    required: HashSet[Period]
    submitted: HashSet[Period]

proc new*(_: type Validation, clock: Clock, market: Market): Validation =
  Validation(clock: clock, market: market)

proc slots*(validation: Validation): seq[SlotId] =
  validation.slots.keys.toSeq

proc getCurrentPeriod(validation: Validation): UInt256 =
  return validation.periodicity.periodOf(validation.clock.now().u256)

proc waitUntilNextPeriod(validation: Validation) {.async.} =
  let period = validation.getCurrentPeriod()
  let periodEnd = validation.periodicity.periodEnd(period)
  await validation.clock.waitUntil(periodEnd.truncate(int64))

proc subscribeSlotFilled(validation: Validation) {.async.} =
  proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
    let slotId = slotId(requestId, slotIndex)
    if not validation.slots.hasKey(slotId):
      validation.slots[slotId] = ProofRequirements()
  let subscription = await validation.market.subscribeSlotFilled(onSlotFilled)
  validation.subscriptions.add(subscription)

proc subscribeProofSubmission(validation: Validation) {.async.} =
  proc onProofSubmission(slotId: SlotId, proof: seq[byte]) =
    let now = validation.getCurrentPeriod()
    if validation.slots.hasKey(slotId):
      try:
        validation.slots[slotId].submitted.incl(now)
      except KeyError:
        raiseAssert "never happens"
  let market = validation.market
  let subscription = await market.subscribeProofSubmission(onProofSubmission)
  validation.subscriptions.add(subscription)

proc removeSlotsThatHaveEnded(validation: Validation) {.async.} =
  var ended: HashSet[SlotId]
  for slotId in validation.slots.keys:
    let state = await validation.market.slotState(slotId)
    if state != SlotState.Filled:
      ended.incl(slotId)
  for slotId in ended:
    validation.slots.del(slotId)

proc recordProofRequirements(validation: Validation) {.async.} =
  for slotId in validation.slots.keys:
    if await validation.market.isProofRequired(slotId):
      let now = validation.getCurrentPeriod()
      validation.slots[slotId].required.incl(now)

proc markProofAsMissing(validation: Validation,
                        slotId: SlotId,
                        period: Period) {.async.} =
  try:
    await validation.market.markProofAsMissing(slotId, period)
  except CancelledError:
    raise
  except CatchableError as e:
    debug "Marking proof as missing failed", msg = e.msg

proc markProofsAsMissing(validation: Validation) {.async.} =
  let timeout = validation.proofTimeout.truncate(int64)
  for slotId in validation.slots.keys:
    let requirements = validation.slots[slotId]
    let ok = intersection(requirements.required, requirements.submitted)
    requirements.required.excl(ok)
    requirements.submitted.excl(ok)
    var handled: HashSet[Period]
    for period in validation.slots[slotId].required:
      let periodEnd = validation.periodicity.periodEnd(period).truncate(int64)
      let now = validation.clock.now()
      if periodEnd <= now:
        if now < periodEnd + timeout:
          await validation.markProofAsMissing(slotId, period)
        handled.incl(period)
    validation.slots[slotId].required.excl(handled)

proc run(validation: Validation) {.async.} =
  try:
    while true:
      await validation.waitUntilNextPeriod()
      await validation.removeSlotsThatHaveEnded()
      await validation.recordProofRequirements()
      await validation.markProofsAsMissing()
  except CancelledError:
    discard
  except CatchableError as e:
    error "Validation failed", msg = e.msg

proc start*(validation: Validation) {.async.} =
  validation.periodicity = await validation.market.periodicity()
  validation.proofTimeout = await validation.market.proofTimeout()
  await validation.subscribeSlotFilled()
  await validation.subscribeProofSubmission()
  validation.running = validation.run()

proc stop*(validation: Validation) {.async.} =
  await validation.running.cancelAndWait()
  while validation.subscriptions.len > 0:
    let subscription = validation.subscriptions.pop()
    await subscription.unsubscribe()
