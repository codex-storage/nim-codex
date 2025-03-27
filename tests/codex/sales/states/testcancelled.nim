import pkg/questionable
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/errored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/market
from pkg/codex/utils/asyncstatemachine import State

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
  var reprocessSlotWas: ?bool
  var returnedCollateralValue: ?UInt256

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
    reprocessSlotWas = bool.none
    returnedCollateralValue = UInt256.none
  teardown:
    reprocessSlotWas = bool.none
    returnedCollateralValue = UInt256.none

  test "calls onCleanUp with reprocessSlot = true, and returnedCollateral = currentCollateral":
    market.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = await market.getSigner(),
      collateral = currentCollateral,
    )
    discard await state.run(agent)
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == some currentCollateral

  test "completes the cancelled state when free slot error is raised and the collateral is returned when a host is hosting a slot":
    market.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = await market.getSigner(),
      collateral = currentCollateral,
    )

    let error =
      newException(SlotStateMismatchError, "Failed to free slot, slot is already free")
    market.setErrorOnFreeSlot(error)

    let next = await state.run(agent)
    check next == none State
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == some currentCollateral

  test "completes the cancelled state when free slot error is raised and the collateral is not returned when a host is not hosting a slot":
    market.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = Address.example,
      collateral = currentCollateral,
    )

    let error =
      newException(SlotStateMismatchError, "Failed to free slot, slot is already free")
    market.setErrorOnFreeSlot(error)

    let next = await state.run(agent)
    check next == none State
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == UInt256.none

  test "calls onCleanUp and returns the collateral when an error is raised":
    market.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = Address.example,
      collateral = currentCollateral,
    )

    let error = newException(MarketError, "")
    market.setErrorOnGetHost(error)

    let next = !(await state.run(agent))

    check next of SaleErrored
    let errored = SaleErrored(next)
    check errored.error == error
