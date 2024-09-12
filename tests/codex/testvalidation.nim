import pkg/chronos
import std/strformat

import codex/validation
import codex/periods

import ../asynctest
import ./helpers/mockmarket
import ./helpers/mockclock
import ./examples
import ./helpers

asyncchecksuite "validation":
  let period = 10
  let timeout = 5
  let maxSlots = 100
  let partitionSize = 8
  let slot = Slot.example
  let proof = Groth16Proof.example
  let collateral = slot.request.ask.collateral

  var validation: Validation
  var market: MockMarket
  var clock: MockClock
  var partitionIndex: int

  func partitionIndexForPartitionSize(slot: Slot, partitionSize: int): int =
    let slotId = slot.id
    let slotIdUInt256 = UInt256.fromBytesBE(slotId.toArray)
    (slotIdUInt256 mod partitionSize.u256).truncate(int)

  setup:
    partitionIndex = slot.partitionIndexForPartitionSize(partitionSize)
    market = MockMarket.new()
    clock = MockClock.new()
    validation = Validation.new(clock, market, maxSlots, partitionSize, partitionIndex)
    market.config.proofs.period = period.u256
    market.config.proofs.timeout = timeout.u256
    await validation.start()

  teardown:
    await validation.stop()

  proc advanceToNextPeriod =
    let periodicity = Periodicity(seconds: period.u256)
    let period = periodicity.periodOf(clock.now().u256)
    let periodEnd = periodicity.periodEnd(period)
    clock.set((periodEnd + 1).truncate(int))

  test "the list of slots that it's monitoring is empty initially":
    check validation.slots.len == 0

  test "when a slot is filled on chain, it is added to the list":
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    check validation.slots == @[slot.id]
  
  test "slot is not observed if it is not in the partition":
    var validation = Validation.new(clock, market, maxSlots, partitionSize, partitionIndex + 1)
    await validation.start()
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == 0
  
  for partitionSize in [0, 1]:
    test fmt"the value of partitionIndex is ignored when {partitionSize = }":
      var validation = Validation.new(clock, market, maxSlots, partitionSize, partitionIndex + 1)
      await validation.start()
      await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
      await validation.stop()
      check validation.slots == @[slot.id]
  
  for outOfRangePartitionIndex in [partitionIndex + partitionSize, (-1)*partitionIndex]:
    test fmt"clips out of range partition indices to `partitionIndex mod partitionSize` (testing for partitionIndex = {outOfRangePartitionIndex}, {partitionSize = })":
      var validation = Validation.new(clock, market, maxSlots, partitionSize, partitionIndex = outOfRangePartitionIndex)
      await validation.start()
      await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
      await validation.stop()
      check validation.slots == @[slot.id]

  for state in [SlotState.Finished, SlotState.Failed]:
    test fmt"when slot state changes to {state}, it is removed from the list":
      await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
      market.slotState[slot.id] = state
      advanceToNextPeriod()
      check eventually validation.slots.len == 0

  test "when a proof is missed, it is marked as missing":
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    market.setCanProofBeMarkedAsMissing(slot.id, true)
    advanceToNextPeriod()
    await sleepAsync(1.millis)
    check market.markedAsMissingProofs.contains(slot.id)

  test "when a proof can not be marked as missing, it will not be marked":
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    market.setCanProofBeMarkedAsMissing(slot.id, false)
    advanceToNextPeriod()
    await sleepAsync(1.millis)
    check market.markedAsMissingProofs.len == 0

  test "it does not monitor more than the maximum number of slots":
    let partitionSize = 1
    let partitionIndex = 0
    let validation = Validation.new(clock, market, maxSlots, partitionSize, partitionIndex)
    await validation.start()
    for _ in 0..<maxSlots + 1:
      let slot = Slot.example
      await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == maxSlots
