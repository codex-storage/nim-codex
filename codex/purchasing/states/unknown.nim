import ../statemachine
import ./submitted
import ./started
import ./cancelled
import ./finished
import ./failed
import ./error

type PurchaseUnknown* = ref object of PurchaseState

method enterAsync(state: PurchaseUnknown) {.async.} =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  try:
    if (request =? await purchase.market.getRequest(purchase.requestId)) and
       (requestState =? await purchase.market.requestState(purchase.requestId)):

      purchase.request = some request

      case requestState
      of RequestState.New:
        state.switch(PurchaseSubmitted())
      of RequestState.Started:
        state.switch(PurchaseStarted())
      of RequestState.Cancelled:
        state.switch(PurchaseCancelled())
      of RequestState.Finished:
        state.switch(PurchaseFinished())
      of RequestState.Failed:
        state.switch(PurchaseFailed())

  except CatchableError as error:
    state.switch(PurchaseErrored(error: error))

method description*(state: PurchaseUnknown): string =
  "unknown"
