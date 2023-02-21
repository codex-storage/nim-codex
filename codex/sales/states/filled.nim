import pkg/questionable
import ./errored
import ./finished
import ./cancelled
import ./failed
import ../statemachine

type
  SaleFilled* = ref object of State
  SaleFilledError* = object of CatchableError
  HostMismatchError* = object of SaleFilledError

method `$`*(state: SaleFilled): string = "SaleFilled"

method run*(state: SaleFilled, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)

  try:
    let market = agent.sales.market

    let slotHost = await market.getHost(agent.request.id, agent.slotIndex)
    agent.slotHost.setValue(slotHost)

  except CancelledError:
    raise
