import std/sets
import pkg/chronos
import pkg/chronicles
import ./market
import ./clock

export market
export sets

type
  Validation* = ref object
    slots*: HashSet[SlotId]
    clock: Clock
    market: Market
    subscriptions: seq[Subscription]
    running: Future[void]

proc new*(_: type Validation, clock: Clock, market: Market): Validation =
  Validation(clock: clock, market: market)

proc subscribeSlotFilled(validation: Validation) {.async.} =
  proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
    validation.slots.incl(slotId(requestId, slotIndex))
  let subscription = await validation.market.subscribeSlotFilled(onSlotFilled)
  validation.subscriptions.add(subscription)

proc subscribeSlotFreed(validation: Validation) {.async.} =
  proc onSlotFreed(slotId: SlotId) =
    validation.slots.excl(slotId)
  let subscription = await validation.market.subscribeSlotFreed(onSlotFreed)
  validation.subscriptions.add(subscription)

proc run(validation: Validation) {.async.} =
  try:
    while true:
      var ended: HashSet[SlotId]
      for slotId in validation.slots:
        let state = await validation.market.slotState(slotId)
        if state != SlotState.Filled:
          ended.incl(slotId)
      validation.slots.excl(ended)
      await sleepAsync(1.seconds) # TODO: wait for next period
  except CancelledError:
    discard
  except CatchableError as e:
    error "Validation failed", msg = e.msg

proc start*(validation: Validation) {.async.} =
  await validation.subscribeSlotFilled()
  await validation.subscribeSlotFreed()
  validation.running = validation.run()

proc stop*(validation: Validation) {.async.} =
  await validation.running.cancelAndWait()
  while validation.subscriptions.len > 0:
    let subscription = validation.subscriptions.pop()
    await subscription.unsubscribe()
