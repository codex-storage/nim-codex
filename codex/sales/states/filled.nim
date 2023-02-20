import pkg/questionable
import ./errored
import ./finished
import ./cancelled
import ./failed
import ../statemachine

type
  SaleFilled* = ref object of SaleState
  SaleFilledError* = object of CatchableError
  HostMismatchError* = object of SaleFilledError

method onCancelled*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleFailed())

method `$`*(state: SaleFilled): string = "SaleFilled"

method run*(state: SaleFilled, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)

  try:
    let market = agent.sales.market

    let slotHost = await market.getHost(agent.request.id, agent.slotIndex)
    agent.slotHost.setValue(slotHost)

  except CancelledError:
    raise

  except CatchableError as e:
    let error = newException(SaleFilledError, "sale filled error", e)
    agent.setError error
