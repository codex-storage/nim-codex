import pkg/questionable
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/sales/states/ignored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/market

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'ignored'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let market = MockMarket.new()
  let clock = MockClock.new()
  let currentCollateral = UInt256.example

  var state: SaleIgnored
  var agent: SalesAgent
  var reprocessSlotWas = false
  var returnedCollateralValue: ?UInt256

  setup:
    let onCleanUp = proc(
        reprocessSlot = false, returnedCollateral = UInt256.none
    ) {.async: (raises: []).} =
      reprocessSlotWas = reprocessSlot
      returnedCollateralValue = returnedCollateral

    let context = SalesContext(market: market, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    agent.onCleanUp = onCleanUp
    state = SaleIgnored.new()
    returnedCollateralValue = UInt256.none
  teardown:
    reprocessSlotWas = false
    returnedCollateralValue = UInt256.none

  test "calls onCleanUp with values assigned to SaleIgnored":
    state = SaleIgnored(reprocessSlot: true)
    discard await state.run(agent)
    check eventually reprocessSlotWas == true
    check eventually returnedCollateralValue.isNone

  test "returns collateral when returnsCollateral is true":
    state = SaleIgnored(reprocessSlot: false, returnsCollateral: true)
    discard await state.run(agent)
    check eventually returnedCollateralValue.isSome
