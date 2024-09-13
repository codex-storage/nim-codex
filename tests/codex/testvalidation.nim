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

  proc initValidationParams(maxSlots: int, partitionSize: int, partitionIndex: int): ValidationParams =
    without validationParams =? ValidationParams.init(maxSlots, partitionSize, partitionIndex), error:
      raiseAssert fmt"Creating ValidationParams failed! Error msg: {error.msg}"
    validationParams
  
  func createValidation(clock: Clock, market: Market, validationParams: ValidationParams): Validation =
    without validation =? Validation.new(clock, market, validationParams), error:
      raiseAssert fmt"Creating Validation failed! Error msg: {error.msg}"
    validation

  func partitionIndexForPartitionSize(slot: Slot, partitionSize: int): int =
    let slotId = slot.id
    let slotIdUInt256 = UInt256.fromBytesBE(slotId.toArray)
    (slotIdUInt256 mod partitionSize.u256).truncate(int)

  setup:
    partitionIndex = slot.partitionIndexForPartitionSize(partitionSize)
    market = MockMarket.new()
    clock = MockClock.new()
    let validationParams = initValidationParams(maxSlots, partitionSize, partitionIndex)
    validation = createValidation(clock, market, validationParams)
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
  
  test "maxSlots in ValidationParams must be greater than 0":
    let maxSlots = 0
    let validationParams: ?!ValidationParams = ValidationParams.init(maxSlots = maxSlots, partitionSize = 1, partitionIndex = 0)
    check validationParams.isFailure == true
    check validationParams.error.msg == fmt"maxSlots must be greater than 0! (got: {maxSlots = })"

  for partitionSize in [-100, -1, 0]:
    test fmt"initializing ValidationParams fails when partitionSize has value our of range (testing for {partitionSize = })":
      let validationParams: ?!ValidationParams = ValidationParams.init(maxSlots, partitionSize = partitionSize, partitionIndex = 0)
      check validationParams.isFailure == true
      check validationParams.error.msg == fmt"Partition size must be greater than 0! (got: {partitionSize = })"
  
  test fmt"initializing ValidationParams fails when partitionIndex is negative":
    let partitionIndex = -1
    let validationParams: ?!ValidationParams = ValidationParams.init(maxSlots, partitionSize = 1, partitionIndex = partitionIndex)
    check validationParams.isFailure == true
    check validationParams.error.msg == fmt"Partition index must be greater than or equal to 0! (got: {partitionIndex = })"

  for (partitionSize, partitionIndex) in [(100, 100), (100, 101)]:
    test fmt"initializing ValidationParams fails when partitionIndex is greater than or equal to partitionSize  (testing for {partitionIndex = }, {partitionSize = })":
      let validationParams: ?!ValidationParams = ValidationParams.init(maxSlots, partitionSize = partitionSize, partitionIndex = partitionIndex)
      check validationParams.isFailure == true
      check validationParams.error.msg == fmt"The value of the partition index must be less than partition size! (got: {partitionIndex = }, {partitionSize = })"

  test "when a slot is filled on chain, it is added to the list":
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    check validation.slots == @[slot.id]
  
  test "slot is not observed if it is not in the partition":
    let validationParams = initValidationParams(maxSlots, partitionSize, partitionIndex + 1)
    let validation = createValidation(clock, market, validationParams)
    await validation.start()
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == 0

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
    let validationParams = initValidationParams(maxSlots, partitionSize = 1, partitionIndex = 0)
    let validation = createValidation(clock, market, validationParams)
    await validation.start()
    for _ in 0..<maxSlots + 1:
      let slot = Slot.example
      await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == maxSlots
