import pkg/questionable
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/sales/states/initialproving
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import pkg/codex/sales/states/filling
import pkg/codex/sales/states/errored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/market

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket

asyncchecksuite "sales state 'initialproving'":
  let proof = exampleProof()
  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256
  let market = MockMarket.new()

  var state: SaleInitialProving
  var agent: SalesAgent
  var receivedChallenge: ProofChallenge

  setup:
    let onProve = proc (slot: Slot, challenge: ProofChallenge): Future[?!seq[byte]] {.async.} =
                          receivedChallenge = challenge
                          return success(proof)
    let context = SalesContext(
      onProve: onProve.some,
      market: market
    )
    agent = newSalesAgent(context,
                          request.id,
                          slotIndex,
                          request.some)
    state = SaleInitialProving.new()

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "switches to filling state when initial proving is complete":
    let next = await state.run(agent)
    check !next of SaleFilling
    check SaleFilling(!next).proof == proof

  test "onProve callback provides proof challenge":
    market.proofChallenge = ProofChallenge.example

    let future = state.run(agent)

    check receivedChallenge == market.proofChallenge

  test "switches to errored state when onProve callback fails":
    let onProveFailed: OnProve = proc(slot: Slot, challenge: ProofChallenge): Future[?!seq[byte]] {.async.} =
      return failure("oh no!")

    let proofFailedContext = SalesContext(
      onProve: onProveFailed.some,
      market: market
    )
    agent = newSalesAgent(proofFailedContext,
                          request.id,
                          slotIndex,
                          request.some)

    let next = await state.run(agent)
    check !next of SaleErrored
