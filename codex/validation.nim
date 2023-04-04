import std/sets
import pkg/chronos
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

proc start*(validation: Validation) {.async.} =
  await validation.subscribeSlotFilled()
  await validation.subscribeSlotFreed()

proc stop*(validation: Validation) {.async.} =
  while validation.subscriptions.len > 0:
    let subscription = validation.subscriptions.pop()
    await subscription.unsubscribe()
