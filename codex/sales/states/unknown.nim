import ../statemachine
import ./filled
import ./finished
import ./failed
import ./errored
import ./cancelled

type
  SaleUnknown* = ref object of SaleState
  SaleUnknownError* = object of CatchableError

method `$`*(state: SaleUnknown): string = "SaleUnknown"

method onCancelled*(state: SaleUnknown, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleCancelled())

method onFailed*(state: SaleUnknown, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleFailed())

method enterAsync(state: SaleUnknown) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  let market = agent.sales.market

  try:
    without requestState =? await market.getState(agent.requestId):
      raiseAssert "state unknown"

    case requestState
    of RequestState.New, RequestState.Started:
      await state.switchAsync(SaleFilled())
    of RequestState.Finished:
      await state.switchAsync(SaleFinished())
    of RequestState.Cancelled:
      await state.switchAsync(SaleCancelled())
    of RequestState.Failed:
      await state.switchAsync(SaleFailed())

  except CancelledError:
    discard

  except CatchableError as e:
    let error = newException(SaleUnknownError,
                             "error in unknown state",
                             e)
    await state.switchAsync(SaleErrored(error: error))
