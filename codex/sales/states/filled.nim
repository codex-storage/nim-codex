import pkg/questionable
import ../statemachine

type
  SaleFilled* = ref object of State
  SaleFilledError* = object of SaleError
  HostMismatchError* = object of SaleFilledError

method `$`*(state: SaleFilled): string = "SaleFilled"

method run*(state: SaleFilled, machine: Machine): Future[?State] {.async.} =
  # echo "running ", state
  let agent = SalesAgent(machine)
  let market = agent.sales.market

  without slotHost =? await market.getHost(agent.requestId, agent.slotIndex):
    let error = newException(SaleFilledError, "Filled slot has no host address")
    agent.setError error
    return

  let me = await market.getSigner()
  if slotHost == me:
    agent.slotHostIsMe.setValue(true)
  else:
    agent.setError newException(HostMismatchError, "Slot filled by other host")
