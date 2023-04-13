import pkg/asynctest
import pkg/chronos

import codex/validation
import ./helpers/mockmarket
import ./helpers/mockclock
import ./helpers/eventually
import ./examples

suite "validation":

  let period = 10
  let timeout = 5
  let slot = Slot.example

  var validation: Validation
  var market: MockMarket
  var clock: MockClock

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    validation = Validation.new(clock, market)
    market.config.proofs.period = period.u256
    market.config.proofs.timeout = timeout.u256
    await validation.start()

  teardown:
    await validation.stop()

  test "the list of slots that it's monitoring is empty initially":
    check validation.slots.len == 0

  test "when a slot is filled on chain, it is added to the list":
    await market.fillSlot(slot.request.id, slot.slotIndex, @[])
    check validation.slots == @[slot.id]

  test "when slot state changes, it is removed from the list":
    await market.fillSlot(slot.request.id, slot.slotIndex, @[])
    market.slotState[slot.id] = SlotState.Finished
    clock.advance(period)
    check eventually validation.slots.len == 0

  test "when a proof is missed, it is marked as missing":
    await market.fillSlot(slot.request.id, slot.slotIndex, @[])
    market.setCanProofBeMarkedAsMissing(slot.id, true)
    clock.advance(period)
    await sleepAsync(1.millis)
    check market.markedAsMissingProofs.contains(slot.id)

  test "when a proof can not be marked as missing, it will not be marked":
    await market.fillSlot(slot.request.id, slot.slotIndex, @[])
    market.setCanProofBeMarkedAsMissing(slot.id, false)
    clock.advance(period)
    await sleepAsync(1.millis)
    check market.markedAsMissingProofs.len == 0

