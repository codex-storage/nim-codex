import pkg/questionable
import pkg/codex/contracts/requests
import pkg/codex/sales/states/finished
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/market

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'finished'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let clock = MockClock.new()

  let currentCollateral = UInt256.example

  var market: MockMarket
  var state: SaleFinished
  var agent: SalesAgent
  var reprocessSlotWas = bool.none
  var returnedCollateralValue = UInt256.none
  var saleCleared = bool.none

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
    agent.context.onClear = some proc(request: StorageRequest, idx: uint64) =
      saleCleared = some true
    state = SaleFinished(returnedCollateral: some currentCollateral)

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "calls onCleanUp with reprocessSlot = true, and returnedCollateral = currentCollateral":
    discard await state.run(agent)
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == some currentCollateral
    check eventually saleCleared == some true
