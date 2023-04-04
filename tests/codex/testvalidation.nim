import pkg/asynctest
import pkg/chronos

import codex/validation
import ./helpers/mockmarket
import ./helpers/mockclock
import ./examples

suite "validation":

  var validation: Validation
  var market: MockMarket
  var clock: MockClock

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    validation = Validation.new(clock, market)
    await validation.start()

  teardown:
    await validation.stop()

  test "the list of slots that it's monitoring is empty initially":
    check validation.slots.len == 0

  test "when a slot is filled on chain, it is added to the list":
    let slot = Slot.example
    await market.fillSlot(slot.request.id, slot.slotIndex, @[])
    check validation.slots == [slot.id].toHashSet

  test "when a slot is freed, it is removed from the list":
    let slot = Slot.example
    await market.fillSlot(slot.request.id, slot.slotIndex, @[])
    await market.freeSlot(slot.id)
    check validation.slots.len == 0
