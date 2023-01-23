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

  test "maintains a list of contract ids to watch":
    let id1, id2 = SlotId.example
    check proving.slots.len == 0
    proving.add(id1)
    check proving.slots.contains(id1)
    proving.add(id2)
    check proving.slots.contains(id1)
    check proving.slots.contains(id2)

  test "removes duplicate contract ids":
    let id = SlotId.example
    proving.add(id)
    proving.add(id)
    check proving.slots.len == 1

  test "invokes callback when proof is required":
    let id = SlotId.example
    proving.add(id)
    var called: bool
    proc onProofRequired(id: SlotId) =
      called = true
    proving.onProofRequired = onProofRequired
    proofs.setSlotState(id, SlotState.Filled)
    proofs.setProofRequired(id, true)
    await proofs.advanceToNextPeriod()
    check eventually called

  test "callback receives id of contract for which proof is required":
    let id1, id2 = SlotId.example
    proving.add(id1)
    proving.add(id2)
    var callbackIds: seq[SlotId]
    proc onProofRequired(id: SlotId) =
      callbackIds.add(id)
    proving.onProofRequired = onProofRequired
    proofs.setSlotState(id1, SlotState.Filled)
    proofs.setSlotState(id2, SlotState.Filled)
    proofs.setProofRequired(id1, true)
    await proofs.advanceToNextPeriod()
    check eventually callbackIds == @[id1]
    proofs.setProofRequired(id1, false)
    proofs.setProofRequired(id2, true)
    await proofs.advanceToNextPeriod()
    check eventually callbackIds == @[id1, id2]

  test "invokes callback when proof is about to be required":
    let id = SlotId.example
    proving.add(id)
    var called: bool
    proc onProofRequired(id: SlotId) =
      called = true
    proving.onProofRequired = onProofRequired
    proofs.setProofRequired(id, false)
    proofs.setProofToBeRequired(id, true)
    proofs.setSlotState(id, SlotState.Filled)
    await proofs.advanceToNextPeriod()
    check eventually called

  test "stops watching when contract has ended":
    let id = SlotId.example
    proving.add(id)
    proofs.setProofEnd(id, clock.now().u256)
    await proofs.advanceToNextPeriod()
    var called: bool
    proc onProofRequired(id: SlotId) =
      called = true
    proving.onProofRequired = onProofRequired
    proofs.setProofRequired(id, true)
    await proofs.advanceToNextPeriod()
    proofs.setSlotState(id, SlotState.Finished)
    check eventually (not proving.slots.contains(id))
    check not called

  test "submits proofs":
    let id = SlotId.example
    let proof = exampleProof()
    await proving.submitProof(id, proof)

  test "supports proof submission subscriptions":
    let id = SlotId.example
    let proof = exampleProof()

    var receivedIds: seq[SlotId]
    var receivedProofs: seq[seq[byte]]

    proc onProofSubmission(id: SlotId, proof: seq[byte]) =
      receivedIds.add(id)
      receivedProofs.add(proof)

    let subscription = await proving.subscribeProofSubmission(onProofSubmission)

    await proving.submitProof(id, proof)

    check receivedIds == @[id]
    check receivedProofs == @[proof]

    await subscription.unsubscribe()
