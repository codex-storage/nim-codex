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

  proc initValidationConfig(maxSlots: MaxSlots,
                            validationGroups: ?ValidationGroups,
                            groupIndex: uint16 = 0): ValidationConfig =
    without validationConfig =? ValidationConfig.init(
      maxSlots, groups=validationGroups, groupIndex), error:
      raiseAssert fmt"Creating ValidationConfig failed! Error msg: {error.msg}"
    validationConfig

  setup:
    groupIndex = groupIndexForSlotId(slot.id, !validationGroups)
    market = MockMarket.new()
    clock = MockClock.new()
    let validationConfig = initValidationConfig(
        maxSlots, validationGroups, groupIndex)
    validation = Validation.new(clock, market, validationConfig)
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
    test "initializing ValidationConfig fails when groupIndex is " &
        "greater than or equal to validationGroups " &
        fmt"(testing for {groupIndex = }, {validationGroups = })":
      let groups = ValidationGroups(validationGroups).some
      let validationConfig = ValidationConfig.init(
          maxSlots, groups = groups, groupIndex = groupIndex)
      check validationConfig.isFailure == true
      check validationConfig.error.msg == "The value of the group index " &
          "must be less than validation groups! " &
          fmt"(got: {groupIndex = }, groups = {!groups})"
  
  test "initializing ValidationConfig fails when maxSlots is negative":
    let maxSlots = -1
    let validationConfig = ValidationConfig.init(
        maxSlots = maxSlots, groups = ValidationGroups.none)
    check validationConfig.isFailure == true
    check validationConfig.error.msg == "The value of maxSlots must " &
        fmt"be greater than or equal to 0! (got: {maxSlots})"
  
  test "initializing ValidationConfig fails when maxSlots is negative " &
      "(validationGroups set)":
    let maxSlots = -1
    let validationConfig = ValidationConfig.init(
        maxSlots = maxSlots, groups = validationGroups, groupIndex)
    check validationConfig.isFailure == true
    check validationConfig.error.msg == "The value of maxSlots must " &
        fmt"be greater than or equal to 0! (got: {maxSlots})"

  test "group index is irrelevant if validation groups are not set":
    randomize()
    let groupIndex = rand(uint16.high.int).uint16
    let validationConfig = ValidationConfig.init(
        maxSlots, groups=ValidationGroups.none, groupIndex)
    check validationConfig.isSuccess

  test "slot is not observed if it is not in the validation group":
    let validationConfig = initValidationConfig(maxSlots, validationGroups,
        (groupIndex + 1) mod uint16(!validationGroups))
    let validation = Validation.new(clock, market, validationConfig)
    await validation.start()
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == 0

  test "when a slot is filled on chain, it is added to the list":
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    check validation.slots == @[slot.id]
  
  test "slot should be observed if maxSlots is set to 0":
    let validationConfig = initValidationConfig(
        maxSlots = 0, ValidationGroups.none)
    let validation = Validation.new(clock, market, validationConfig)
    await validation.start()
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots == @[slot.id]

  test "slot should be observed if validation group is not set (and " &
      "maxSlots is not 0)":
    let validationConfig = initValidationConfig(
        maxSlots, ValidationGroups.none)
    let validation = Validation.new(clock, market, validationConfig)
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
    let validationGroups = ValidationGroups.none
    let validationConfig = initValidationConfig(
        maxSlots, validationGroups)
    let validation = Validation.new(clock, market, validationConfig)
    await validation.start()
    for _ in 0..<maxSlots + 1:
      let slot = Slot.example
      await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == maxSlots
  
  proc setupAndStartValidation(maxSlots: MaxSlots,
                               validationGroups: ?ValidationGroups,
                               groupIndex: uint16
                              ): Future[Validation] {.async.} =
    let validationConfig = initValidationConfig(
      maxSlots, validationGroups, groupIndex)
    let validation = Validation.new(clock, market, validationConfig)
    await validation.start()
    validation

  proc setupValidationGroup(slotId: SlotId,
                            maxSlots: MaxSlots,
                            groups: ?ValidationGroups,
                            groupIndex: uint16,
                            slotsInSelectedGroup: var int,
                            slots: var HashSet) =
    if validationGroups =? groups:
      if groupIndexForSlotId(slotId, validationGroups) == groupIndex:
        slotsInSelectedGroup += 1
        if maxSlots == 0:
          slots.incl(slotId)
        elif slotsInSelectedGroup <= maxSlots:
          slots.incl(slotId)
    else:
      if maxSlots == 0:
        slots.incl(slotId)
      elif slots.len < maxSlots:
        slots.incl(slotId)

  func calculateExpectedSlots(maxSlots: MaxSlots,
                              groups: ?ValidationGroups,
                              slots: HashSet): int =
    if validationGroups.isNone:
      return if maxSlots == 0: 100 else: maxSlots
    
    if maxSlots == 0 or slots.len < maxSlots:
      return slots.len
    else:
      return maxSlots
  
  proc printExtraTestInfo(maxSlots: MaxSlots,
                          validationGroups: ?ValidationGroups,
                          groupIndex: uint16,
                          slotsInSelectedGroup: int,
                          expectedSlots: int) =
    echo "---------------------------------------------------------" &
            "---------------------------------------------------------"
    if validationGroups.isNone:
      echo fmt"       ⬇︎ {maxSlots=}, {validationGroups=}, " &
          fmt"{groupIndex=}: {expectedSlots=} ⬇︎"
    else:
      echo fmt"       ⬇︎ {maxSlots=}, {validationGroups=}, " &
          fmt"{groupIndex=}: {slotsInSelectedGroup=}, {expectedSlots=} ⬇︎"
      
  # This test is a bit more complex, but it allows us to test the
  # assignment of slots to different validation groups in combination with
  # the maxSlots constraint.
  # It is not pragmatic to generate a slot with id that will go to the
  # intended group. In other tests, after creating an example slot, we
  # compute the group id it is expected to be in, and dependeing on if 
  # we want to test that it is observed or not, we create validation params
  # with the computed expected groupIndex or with groupIndex+1 respectively.
  # In those tests we test only one slot and one groupIndex. In this test
  # we can test multiple slots going to specific group in one test.
  # Moreover for the selected group we can also test that maxSlots
  # constraint is respected also when groups are enabled (the other test we
  # have defined earlier, tests that the maxSlots constraint only for
  # the case when groups are not enabled). Finally, this tests should also
  # allow us to document better what happens when maxSlots is set to 0.
  for (maxSlots, validationGroups, groupIndex) in [
                                       (0, ValidationGroups.none, 0),
                                       (0, ValidationGroups.none, 1),
                                       (0, ValidationGroups(2).some, 0),
                                       (0, ValidationGroups(2).some, 1),
                                       (10, ValidationGroups.none, 0),
                                       (10, ValidationGroups.none, 1),
                                       (10, ValidationGroups(2).some, 0),
                                       (10, ValidationGroups(2).some, 1)]:
    test fmt"slots should be observed ({maxSlots=}, {validationGroups=}, " &
        fmt"{groupIndex=})":
      let validation = await setupAndStartValidation(
        maxSlots, validationGroups, groupIndex.uint16)
      var slotsInSelectedGroup = 0
      var slots = initHashSet[SlotId]()
      # The number of slots should be big enough so that we are
      # sure that at least some of them endup in the intended group.
      # By probability, it is expected that they will distribute
      # evenly between the groups.
      for i in 0..<100:
        let slot = Slot.example
        setupValidationGroup(slot.id, maxSlots, validationGroups,
          groupIndex.uint16, slotsInSelectedGroup, slots)
        await market.fillSlot(slot.request.id, slot.slotIndex,
          proof, collateral)
      await validation.stop()
      let expectedSlots = calculateExpectedSlots(
        maxSlots, validationGroups, slots)
      printExtraTestInfo(maxSlots, validationGroups, groupIndex.uint16,
                         slotsInSelectedGroup, expectedSlots)
      check validation.slots.len == expectedSlots
      check slots == toHashSet(validation.slots)
