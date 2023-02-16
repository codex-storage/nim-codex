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

    let host = await market.getHost(agent.requestId, agent.slotIndex)
    let me = await market.getSigner()
    if host == me.some:
      return some State(SaleFinished())
    else:
      let error = newException(HostMismatchError, "Slot filled by other host")
      return some State(SaleErrored(error: error))

  except CancelledError:
    raise

  except CatchableError as e:
    let error = newException(SaleFilledError, "sale filled error", e)
    return some State(SaleErrored(error: error))
