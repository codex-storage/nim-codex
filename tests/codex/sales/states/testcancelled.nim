import pkg/questionable
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/market
from pkg/codex/contracts/marketplace import Marketplace_SlotIsFree

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'cancelled'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let clock = MockClock.new()

  let currentCollateral = UInt256.example

  var market: MockMarket
  var state: SaleCancelled
  var agent: SalesAgent
  var reprocessSlotWas = bool.none
  var returnedCollateralValue = UInt256.none

  setup:
    market = MockMarket.new()
    let onCleanUp = proc(
        reprocessSlot = false, returnedCollateral = UInt256.none
    ) {.async.} =
      reprocessSlotWas = some reprocessSlot
      returnedCollateralValue = returnedCollateral

    let context = SalesContext(market: market, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    agent.onCleanUp = onCleanUp
    state = SaleCancelled.new()

  teardown:
    reprocessSlotWas = bool.none
    returnedCollateralValue = UInt256.none

  test "calls onCleanUp with reprocessSlot = true, and returnedCollateral = currentCollateral":
    market.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = Address.example,
      collateral = currentCollateral,
    )
    discard await state.run(agent)
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == some currentCollateral

  test "calls onCleanUp and returns the collateral when free slot error is raised":
    market.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = Address.example,
      collateral = currentCollateral,
    )

    let error = newException(Marketplace_SlotIsFree, "")
    market.setSlotThrowError(some cast[ref CatchableError](error))

    discard await state.run(agent)
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == some currentCollateral
