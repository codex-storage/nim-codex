import ../statemachine
import ./submitted
import ./started
import ./cancelled
import ./error

type PurchaseUnknown* = ref object of PurchaseState

method enterAsync(state: PurchaseUnknown) {.async.} =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  try:
    if requestState =? await purchase.market.getState(purchase.request.id):
      case requestState
      of RequestState.New:
        state.switch(PurchaseSubmitted())
      of RequestState.Started:
        state.switch(PurchaseStarted())
      of RequestState.Cancelled:
        state.switch(PurchaseCancelled())
      of RequestState.Finished:
        discard # TODO
      of RequestState.Failed:
        discard # TODO
  except CatchableError as error:
    state.switch(PurchaseError(error: error))
