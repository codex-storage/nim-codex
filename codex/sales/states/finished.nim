import pkg/chronos
import ./cancelled
import ./errored
import ./failed
import ../statemachine

type
  SaleFinished* = ref object of SaleState
  SaleFinishedError* = object of CatchableError

method `$`*(state: SaleFinished): string = "SaleFinished"

method onCancelled*(state: SaleFinished, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleCancelled())

method onFailed*(state: SaleFinished, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleFailed())

method enterAsync*(state: SaleFinished) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  try:
    if request =? agent.request and
        slotIndex =? agent.slotIndex:
      agent.sales.proving.add(request.slotId(slotIndex))

      if onSale =? agent.sales.onSale:
        onSale(agent.availability, request, slotIndex)

    # TODO: Keep track of contract completion using local clock. When contract
    # has finished, we need to add back availability to the sales module.
    # This will change when the state machine is updated to include the entire
    # sales process, as well as when availability is persisted, so leaving it
    # as a TODO for now.

  except CancelledError:
    discard

  except CatchableError as e:
    let error = newException(SaleFinishedError, "sale finished error", e)
    await state.switchAsync(SaleErrored(error: error))
