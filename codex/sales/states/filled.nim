import pkg/questionable
import ../statemachine
import ../salesagent
import ./errorhandling
import ./errored
import ./finished
import ./cancelled
import ./failed

type
  SaleFilled* = ref object of ErrorHandlingState
  HostMismatchError* = object of CatchableError

method onCancelled*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleFailed())

method `$`*(state: SaleFilled): string = "SaleFilled"

method run*(state: SaleFilled, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let market = SalesAgent(machine).context.market

  let host = await market.getHost(data.requestId, data.slotIndex)
  let me = await market.getSigner()
  if host == me.some:
    return some State(SaleFinished())
  else:
    let error = newException(HostMismatchError, "Slot filled by other host")
    return some State(SaleErrored(error: error))
