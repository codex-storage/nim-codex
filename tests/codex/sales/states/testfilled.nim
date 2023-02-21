import pkg/asynctest
import pkg/codex/contracts/requests
import pkg/codex/sales
import pkg/codex/sales/states/filled
import pkg/codex/sales/states/errored
import pkg/codex/sales/states/finished
import ../../helpers/mockmarket
import ../../examples

suite "sales state 'filled'":

  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256
  let slotId = slotId(request.id, slotIndex)

  var market: MockMarket
  var slot: MockSlot
  var sales: Sales
  var agent: SalesAgent
  var state: SaleFilled

  setup:
    market = MockMarket.new()
    slot = MockSlot(requestId: request.id,
                    host: Address.example,
                    slotIndex: slotIndex,
                    proof: @[])
    sales = Sales.new(market, nil, nil)
    agent = sales.newSalesAgent(request.id,
                                slotIndex,
                                Availability.none,
                                StorageRequest.none)
    state = SaleFilled.new()

  test "switches to finished state when slot is filled by me":
    slot.host = await market.getSigner()
    market.filled = @[slot]
    let next = await state.run(agent)
    check !next of SaleFinished

  test "switches to error state when slot is filled by another host":
    slot.host = Address.example
    market.filled = @[slot]
    let next = await state.run(agent)
    check !next of SaleErrored
