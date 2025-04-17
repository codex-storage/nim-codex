import pkg/questionable
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/sales/states/errored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/market

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'errored'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let market = MockMarket.new()
  let clock = MockClock.new()

  var state: SaleErrored
  var agent: SalesAgent
  var reprocessSlotWas = false

  setup:
    let onCleanUp = proc(
        reprocessSlot = false, returnedCollateral = Tokens.none
    ) {.async.} =
      reprocessSlotWas = reprocessSlot

    let context = SalesContext(market: market, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    agent.onCleanUp = onCleanUp
    state = SaleErrored(error: newException(ValueError, "oh no!"))

  test "calls onCleanUp with reprocessSlot = true":
    state = SaleErrored(error: newException(ValueError, "oh no!"), reprocessSlot: true)
    discard await state.run(agent)
    check eventually reprocessSlotWas == true
