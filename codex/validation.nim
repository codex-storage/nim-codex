import std/sets
import std/sequtils
import pkg/chronos
import ./market
import ./clock
import ./logutils

export market
export sets

type
  Validation* = ref object
    slots: HashSet[SlotId]
    maxSlots: int
    partitionSize: int
    partitionIndex: int
    clock: Clock
    market: Market
    subscriptions: seq[Subscription]
    running: Future[void]
    periodicity: Periodicity
    proofTimeout: UInt256

logScope:
  topics = "codex validator"

proc new*(
    _: type Validation,
    clock: Clock,
    market: Market,
    maxSlots: int,
    partitionSize: int,
    partitionIndex: int
): Validation =
  ## Create a new Validation instance
  Validation(clock: clock, market: market, maxSlots: maxSlots, partitionSize: partitionSize, partitionIndex: if [0, 1].anyIt(it == partitionSize): 0 else: partitionIndex mod partitionSize)

proc slots*(validation: Validation): seq[SlotId] =
  validation.slots.toSeq

proc getCurrentPeriod(validation: Validation): UInt256 =
  return validation.periodicity.periodOf(validation.clock.now().u256)

proc waitUntilNextPeriod(validation: Validation) {.async.} =
  let period = validation.getCurrentPeriod()
  let periodEnd = validation.periodicity.periodEnd(period)
  trace "Waiting until next period", currentPeriod = period
  await validation.clock.waitUntil(periodEnd.truncate(int64) + 1)

func partitionIndexForSlotId(validation: Validation, slotId: SlotId): int =
  if (validation.partitionSize == 0):
    0
  else:
    let slotIdUInt256 = UInt256.fromBytesBE(slotId.toArray)
    (slotIdUInt256 mod validation.partitionSize.u256).truncate(int)

func shouldValidateSlot(validation: Validation, slotId: SlotId): bool =
  return (
    validation.partitionIndexForSlotId(slotId) == validation.partitionIndex and
    slotId notin validation.slots and
    validation.slots.len < validation.maxSlots
  )

proc subscribeSlotFilled(validation: Validation) {.async.} =
  proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
    let slotId = slotId(requestId, slotIndex)
    if validation.shouldValidateSlot(slotId):
      trace "Adding slot", slotId
      validation.slots.incl(slotId)
  let subscription = await validation.market.subscribeSlotFilled(onSlotFilled)
  validation.subscriptions.add(subscription)

proc removeSlotsThatHaveEnded(validation: Validation) {.async.} =
  var ended: HashSet[SlotId]
  let slots = validation.slots
  for slotId in slots:
    let state = await validation.market.slotState(slotId)
    if state != SlotState.Filled:
      trace "Removing slot", slotId
      ended.incl(slotId)
  validation.slots.excl(ended)

proc markProofAsMissing(validation: Validation,
                        slotId: SlotId,
                        period: Period) {.async.} =
  logScope:
    currentPeriod = validation.getCurrentPeriod()

  try:
    if await validation.market.canProofBeMarkedAsMissing(slotId, period):
      trace "Marking proof as missing", slotId, periodProofMissed = period
      await validation.market.markProofAsMissing(slotId, period)
    else:
      let inDowntime {.used.} = await validation.market.inDowntime(slotId)
      trace "Proof not missing", checkedPeriod = period, inDowntime
  except CancelledError:
    raise
  except CatchableError as e:
    error "Marking proof as missing failed", msg = e.msg

proc markProofsAsMissing(validation: Validation) {.async.} =
  let slots = validation.slots
  for slotId in slots:
    let previousPeriod = validation.getCurrentPeriod() - 1
    await validation.markProofAsMissing(slotId, previousPeriod)

proc run(validation: Validation) {.async.} =
  trace "Validation started"
  try:
    while true:
      await validation.waitUntilNextPeriod()
      await validation.removeSlotsThatHaveEnded()
      await validation.markProofsAsMissing()
  except CancelledError:
    trace "Validation stopped"
    discard
  except CatchableError as e:
    error "Validation failed", msg = e.msg

proc start*(validation: Validation) {.async.} =
  validation.periodicity = await validation.market.periodicity()
  validation.proofTimeout = await validation.market.proofTimeout()
  await validation.subscribeSlotFilled()
  validation.running = validation.run()

proc stop*(validation: Validation) {.async.} =
  await validation.running.cancelAndWait()
  while validation.subscriptions.len > 0:
    let subscription = validation.subscriptions.pop()
    await subscription.unsubscribe()
