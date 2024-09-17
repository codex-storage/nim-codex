import pkg/chronos
import std/strformat
import std/random

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
  let maxSlots = MaxSlots(100)
  let validationGroups = ValidationGroups(8).some
  let slot = Slot.example
  let proof = Groth16Proof.example
  let collateral = slot.request.ask.collateral

  var validation: Validation
  var market: MockMarket
  var clock: MockClock
  var groupIndex: uint16

  proc initValidationParams(maxSlots: MaxSlots, validationGroups: ?ValidationGroups, groupIndex: uint16): ValidationParams =
    without validationParams =? ValidationParams.init(maxSlots, groups=validationGroups, groupIndex), error:
      raiseAssert fmt"Creating ValidationParams failed! Error msg: {error.msg}"
    validationParams
  
  func createValidation(clock: Clock, market: Market, validationParams: ValidationParams): Validation =
    without validation =? Validation.new(clock, market, validationParams), error:
      raiseAssert fmt"Creating Validation failed! Error msg: {error.msg}"
    validation

  setup:
    groupIndex = groupIndexForSlotId(slot.id, !validationGroups)
    market = MockMarket.new()
    clock = MockClock.new()
    let validationParams = initValidationParams(maxSlots, validationGroups, groupIndex)
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

  for (validationGroups, groupIndex) in [(100, 100'u16), (100, 101'u16)]:
    test fmt"initializing ValidationParams fails when groupIndex is greater than or equal to validationGroups (testing for {groupIndex = }, {validationGroups = })":
      let groups = ValidationGroups(validationGroups).some
      let validationParams: ?!ValidationParams = ValidationParams.init(maxSlots, groups = groups, groupIndex = groupIndex)
      check validationParams.isFailure == true
      check validationParams.error.msg == fmt"The value of the group index must be less than validation groups! (got: {groupIndex = }, groups = {!groups})"
  
  test "group index is irrelevant if validation groups are not set":
    randomize()
    for _ in 0..<100:
      let groupIndex = rand(1000).uint16
      let validationParams = ValidationParams.init(maxSlots, groups=ValidationGroups.none, groupIndex)
      check validationParams.isSuccess
  
  test "slot should be observed if it is in the validation group":
    let validationParams = initValidationParams(maxSlots, validationGroups, groupIndex)
    let validation = createValidation(clock, market, validationParams)
    check validation.shouldValidateSlot(slot.id) == true
  
  test "slot should be observed if validation group is not set":
    let validationParams = initValidationParams(maxSlots, ValidationGroups.none, groupIndex)
    let validation = createValidation(clock, market, validationParams)
    check validation.shouldValidateSlot(slot.id) == true
  
  test "slot should not be observed if it is not in the validation group":
    let validationParams = initValidationParams(maxSlots, validationGroups, (groupIndex + 1) mod uint16(!validationGroups))
    let validation = createValidation(clock, market, validationParams)
    check validation.shouldValidateSlot(slot.id) == false
  
  test "slot is not observed if it is not in the validation group":
    let validationParams = initValidationParams(maxSlots, validationGroups, (groupIndex + 1) mod uint16(!validationGroups))
    let validation = createValidation(clock, market, validationParams)
    await validation.start()
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == 0

  test "when a slot is filled on chain, it is added to the list":
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
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
    let validationGroups = ValidationGroups.none
    let validationParams = initValidationParams(maxSlots, validationGroups, groupIndex = 0'u16)
    let validation = createValidation(clock, market, validationParams)
    await validation.start()
    for _ in 0..<maxSlots + 1:
      let slot = Slot.example
      await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == maxSlots
