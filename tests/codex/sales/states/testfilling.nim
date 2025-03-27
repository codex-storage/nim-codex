import pkg/questionable
import pkg/codex/contracts/requests
import pkg/codex/sales/states/filling
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import pkg/codex/sales/states/ignored
import pkg/codex/sales/states/errored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

suite "sales state 'filling'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  var state: SaleFilling
  var market: MockMarket
  var clock: MockClock
  var agent: SalesAgent

  setup:
    clock = MockClock.new()
    market = MockMarket.new()
    let context = SalesContext(market: market, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    state = SaleFilling.new()

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "run switches to ignored when slot is not free":
    let error = newException(
      SlotStateMismatchError, "Failed to fill slot because the slot is not free"
    )
    market.setErrorOnFillSlot(error)
    market.requested.add(request)
    market.slotState[request.slotId(slotIndex)] = SlotState.Filled

    let next = !(await state.run(agent))
    check next of SaleIgnored
    check SaleIgnored(next).reprocessSlot == false

  test "run switches to errored with other error ":
    let error = newException(MarketError, "some error")
    market.setErrorOnFillSlot(error)
    market.requested.add(request)
    market.slotState[request.slotId(slotIndex)] = SlotState.Filled

    let next = !(await state.run(agent))
    check next of SaleErrored

    let errored = SaleErrored(next)
    check errored.error == error
