import pkg/upraises
import ../../market
import ../statemachine
import ./filled
import ./errored
import ./cancelled
import ./failed

type
  SaleFilling* = ref object of SaleState
    proof*: seq[byte]
  SaleFillingError* = object of CatchableError

method `$`*(state: SaleFilling): string = "SaleFilling"

method run(state: SaleFilling, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)

  try:
    let market = agent.sales.market

    await market.fillSlot(agent.request.id, agent.slotIndex, state.proof)

  except CancelledError:
    raise
