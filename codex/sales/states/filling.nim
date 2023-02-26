import ../../market
import ../statemachine

type
  SaleFilling* = ref object of State
  SaleFillingError* = object of SaleError

method `$`*(state: SaleFilling): string = "SaleFilling"

method run(state: SaleFilling, machine: Machine): Future[?State] {.async.} =
  # echo "running ", state
  let agent = SalesAgent(machine)
  let market = agent.sales.market

  await market.fillSlot(agent.requestId, agent.slotIndex, agent.proof.value)
