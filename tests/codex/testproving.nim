import pkg/asynctest
import pkg/chronos
import pkg/codex/proving
import ./helpers/mockproofs
import ./helpers/mockclock
import ./helpers/eventually
import ./examples

suite "Proving":

  var proving: Proving
  var proofs: MockProofs
  var clock: MockClock

  setup:
    proofs = MockProofs.new()
    clock = MockClock.new()
    proving = Proving.new(proofs, clock)
    await proving.start()

  teardown:
    await proving.stop()

  proc advanceToNextPeriod(proofs: MockProofs) {.async.} =
    let periodicity = await proofs.periodicity()
    clock.advance(periodicity.seconds.truncate(int64))

  test "maintains a list of slots to watch":
    let slot1, slot2 = Slot.example
    check proving.slots.len == 0
    proving.add(slot1)
    check proving.slots.contains(slot1)
    proving.add(slot2)
    check proving.slots.contains(slot1)
    check proving.slots.contains(slot2)

  test "removes duplicate slots":
    let slot = Slot.example
    proving.add(slot)
    proving.add(slot)
    check proving.slots.len == 1

  test "invokes callback when proof is required":
    let slot = Slot.example
    proving.add(slot)
    var called: bool
    proc onProve(slot: Slot): Future[seq[byte]] {.async.} =
      called = true
    proving.onProve = onProve
    proofs.setSlotState(slot.id, SlotState.Filled)
    proofs.setProofRequired(slot.id, true)
    await proofs.advanceToNextPeriod()
    check eventually called

  test "callback receives slot for which proof is required":
    let slot1, slot2 = Slot.example
    proving.add(slot1)
    proving.add(slot2)
    var callbackSlots: seq[Slot]
    proc onProve(slot: Slot): Future[seq[byte]] {.async.} =
      callbackSlots.add(slot)
    proving.onProve = onProve
    proofs.setSlotState(slot1.id, SlotState.Filled)
    proofs.setSlotState(slot2.id, SlotState.Filled)
    proofs.setProofRequired(slot1.id, true)
    await proofs.advanceToNextPeriod()
    check eventually callbackSlots == @[slot1]
    proofs.setProofRequired(slot1.id, false)
    proofs.setProofRequired(slot2.id, true)
    await proofs.advanceToNextPeriod()
    check eventually callbackSlots == @[slot1, slot2]

  test "invokes callback when proof is about to be required":
    let slot = Slot.example
    proving.add(slot)
    var called: bool
    proc onProve(slot: Slot): Future[seq[byte]] {.async.} =
      called = true
    proving.onProve = onProve
    proofs.setProofRequired(slot.id, false)
    proofs.setProofToBeRequired(slot.id, true)
    proofs.setSlotState(slot.id, SlotState.Filled)
    await proofs.advanceToNextPeriod()
    check eventually called

  test "stops watching when slot is finished":
    let slot = Slot.example
    proving.add(slot)
    proofs.setProofEnd(slot.id, clock.now().u256)
    await proofs.advanceToNextPeriod()
    var called: bool
    proc onProve(slot: Slot): Future[seq[byte]] {.async.} =
      called = true
    proving.onProve = onProve
    proofs.setProofRequired(slot.id, true)
    await proofs.advanceToNextPeriod()
    proofs.setSlotState(slot.id, SlotState.Finished)
    check eventually (not proving.slots.contains(slot))
    check not called

  test "submits proofs":
    let slot = Slot.example
    let proof = exampleProof()

    proving.onProve = proc (slot: Slot): Future[seq[byte]] {.async.} =
      return proof

    var receivedIds: seq[SlotId]
    var receivedProofs: seq[seq[byte]]

    proc onProofSubmission(id: SlotId, proof: seq[byte]) =
      receivedIds.add(id)
      receivedProofs.add(proof)

    let subscription = await proving.subscribeProofSubmission(onProofSubmission)

    proving.add(slot)
    proofs.setSlotState(slot.id, SlotState.Filled)
    proofs.setProofRequired(slot.id, true)
    await proofs.advanceToNextPeriod()

    check eventually receivedIds == @[slot.id] and receivedProofs == @[proof]

    await subscription.unsubscribe()
