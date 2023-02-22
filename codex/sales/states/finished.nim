import pkg/chronos
import ./cancelled
import ./errored
import ./failed
import ../statemachine

type
  SaleFinished* = ref object of SaleState
  SaleFinishedError* = object of CatchableError

method `$`*(state: SaleFinished): string = "SaleFinished"

method onCancelled*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(state: SaleFinished, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let sales = SalesAgent(machine).sales

  try:
    if request =? data.request and
        slotIndex =? data.slotIndex:
      sales.proving.add(request.slotId(slotIndex))

      if onSale =? sales.onSale:
        onSale(data.availability, request, slotIndex)

    # TODO: Keep track of contract completion using local clock. When contract
    # has finished, we need to add back availability to the sales module.
    # This will change when the state machine is updated to include the entire
    # sales process, as well as when availability is persisted, so leaving it
    # as a TODO for now.

  except CancelledError:
    raise

  except CatchableError as e:
    let error = newException(SaleFinishedError, "sale finished error", e)
    return some State(SaleErrored(error: error))
