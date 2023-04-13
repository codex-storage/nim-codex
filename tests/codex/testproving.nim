import std/sequtils
import pkg/asynctest
import pkg/chronos
import pkg/codex/proving
import ./helpers/mockmarket
import ./helpers/mockclock
import ./helpers/eventually
import ./examples

suite "Proving":

  var proving: Proving
  var market: MockMarket
  var clock: MockClock

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    proving = Proving.new(market, clock)
    await proving.start()

  teardown:
    await proving.stop()

  proc advanceToNextPeriod(market: MockMarket) {.async.} =
    let periodicity = await market.periodicity()
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
    market.slotState[slot.id] = SlotState.Filled
    market.setProofRequired(slot.id, true)
    await market.advanceToNextPeriod()
    check eventually called

  test "callback receives slot for which proof is required":
    let slot1, slot2 = Slot.example
    proving.add(slot1)
    proving.add(slot2)
    var callbackSlots: seq[Slot]
    proc onProve(slot: Slot): Future[seq[byte]] {.async.} =
      callbackSlots.add(slot)
    proving.onProve = onProve
    market.slotState[slot1.id] = SlotState.Filled
    market.slotState[slot2.id] = SlotState.Filled
    market.setProofRequired(slot1.id, true)
    await market.advanceToNextPeriod()
    check eventually callbackSlots == @[slot1]
    market.setProofRequired(slot1.id, false)
    market.setProofRequired(slot2.id, true)
    await market.advanceToNextPeriod()
    check eventually callbackSlots == @[slot1, slot2]

  test "invokes callback when proof is about to be required":
    let slot = Slot.example
    proving.add(slot)
    var called: bool
    proc onProve(slot: Slot): Future[seq[byte]] {.async.} =
      called = true
    proving.onProve = onProve
    market.setProofRequired(slot.id, false)
    market.setProofToBeRequired(slot.id, true)
    market.slotState[slot.id] = SlotState.Filled
    await market.advanceToNextPeriod()
    check eventually called

  test "stops watching when slot is finished":
    let slot = Slot.example
    proving.add(slot)
    market.setProofEnd(slot.id, clock.now().u256)
    await market.advanceToNextPeriod()
    var called: bool
    proc onProve(slot: Slot): Future[seq[byte]] {.async.} =
      called = true
    proving.onProve = onProve
    market.setProofRequired(slot.id, true)
    await market.advanceToNextPeriod()
    market.slotState[slot.id] = SlotState.Finished
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
    market.slotState[slot.id] = SlotState.Filled
    market.setProofRequired(slot.id, true)
    await market.advanceToNextPeriod()

    check eventually receivedIds == @[slot.id] and receivedProofs == @[proof]

    await subscription.unsubscribe()

suite "Simulated proving":

  var proving: SimulatedProving
  var subscription: Subscription
  var market: MockMarket
  var clock: MockClock
  var submitted: seq[seq[byte]]
  var proof: seq[byte]
  let slot = Slot.example
  var proofSubmitted: Future[void]

  setup:
    proof = exampleProof()
    submitted = @[]
    market = MockMarket.new()
    clock = MockClock.new()
    proofSubmitted = newFuture[void]("proofSubmitted")

  teardown:
    await subscription.unsubscribe()
    await proving.stop()

  proc newSimulatedProving(failEveryNProofs: uint) {.async.} =
    proc onProofSubmission(id: SlotId, proof: seq[byte]) =
      submitted.add(proof)
      proofSubmitted.complete()
      proofSubmitted = newFuture[void]("proofSubmitted")

    proving = SimulatedProving.new(market, clock, failEveryNProofs)
    proving.onProve = proc (slot: Slot): Future[seq[byte]] {.async.} =
      return proof
    subscription = await proving.subscribeProofSubmission(onProofSubmission)
    proving.add(slot)
    market.slotState[slot.id] = SlotState.Filled
    market.setProofRequired(slot.id, true)
    await proving.start()

  proc advanceToNextPeriod(market: Market) {.async.} =
    let periodicity = await market.periodicity()
    clock.advance(periodicity.seconds.truncate(int64))

  proc waitForProvingRounds(market: Market, rounds: uint) {.async.} =
    var rnds = rounds - 1 # proof round runs prior to advancing
    while rnds > 0:
      await market.advanceToNextPeriod()
      await proofSubmitted
      rnds -= 1

  test "submits invalid proof every 3 proofs":
    let failEveryNProofs = 3'u
    let totalProofs = 6'u
    await newSimulatedProving(failEveryNProofs)
    await market.waitForProvingRounds(totalProofs)
    check submitted == @[proof, proof, @[], proof, proof, @[]]

  test "does not submit invalid proofs when failEveryNProofs is 0":
    let failEveryNProofs = 0'u
    let totalProofs = 6'u
    await newSimulatedProving(failEveryNProofs)
    await market.waitForProvingRounds(totalProofs)
    check submitted == proof.repeat(totalProofs)

  test "does not submit invalid proofs when current chain is mainnet":
    let failEveryNProofs = 3'u
    let totalProofs = 6'u
    market.setMainnet(true)
    await newSimulatedProving(failEveryNProofs)
    await market.waitForProvingRounds(totalProofs)
    check submitted == proof.repeat(totalProofs)
