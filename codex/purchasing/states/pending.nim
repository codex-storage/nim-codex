import ../statemachine
import ./submitted
import ./error

type PurchasePending* = ref object of PurchaseState

method enterAsync(state: PurchasePending) {.async.} =
  without purchase =? (state.context as Purchase) and
          request =? purchase.request:
    raiseAssert "invalid state"

  try:
    await purchase.market.requestStorage(request)
  except CatchableError as error:
    state.switch(PurchaseErrored(error: error))
    return

  state.switch(PurchaseSubmitted())

method description*(state: PurchasePending): string =
  "pending"
