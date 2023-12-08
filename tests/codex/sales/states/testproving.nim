import pkg/asynctest
import pkg/chronos
import pkg/questionable
import pkg/codex/contracts/requests
import pkg/codex/sales/states/proving
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import pkg/codex/sales/states/payout
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'proving'":

  let slot = Slot.example
  let request = slot.request
  let proof = exampleProof()

  var market: MockMarket
  var clock: MockClock
  var agent: SalesAgent
  var state: SaleProving

  setup:
    clock = MockClock.new()
    market = MockMarket.new()
    let onProve = proc (slot: Slot, challenge: ProofChallenge): Future[seq[byte]] {.async.} =
                        return proof
    let context = SalesContext(market: market, clock: clock, onProve: onProve.some)
    agent = newSalesAgent(context,
                          request.id,
                          slot.slotIndex,
                          request.some)
    state = SaleProving.new()

  proc advanceToNextPeriod(market: Market) {.async.} =
    let periodicity = await market.periodicity()
    clock.advance(periodicity.seconds.truncate(int64))

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "submits proofs":
    var receivedIds: seq[SlotId]
    var receivedProofs: seq[seq[byte]]

    proc onProofSubmission(id: SlotId, proof: seq[byte]) =
      receivedIds.add(id)
      receivedProofs.add(proof)

    let subscription = await market.subscribeProofSubmission(onProofSubmission)
    market.slotState[slot.id] = SlotState.Filled

    let future = state.run(agent)

    market.setProofRequired(slot.id, true)
    await market.advanceToNextPeriod()

    check eventually receivedIds == @[slot.id] and receivedProofs == @[proof]

    await future.cancelAndWait()
    await subscription.unsubscribe()

  test "switches to payout state when request is finished":
    market.slotState[slot.id] = SlotState.Filled

    let future = state.run(agent)

    market.slotState[slot.id] = SlotState.Finished
    await market.advanceToNextPeriod()

    check eventually future.finished
    check !(future.read()) of SalePayout

