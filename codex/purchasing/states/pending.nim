import ../statemachine
import ./submitted
import ./error

type PurchasePending* = ref object of PurchaseState

method enterAsync(state: PurchasePending) {.async.} =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  try:
    purchase.request = await purchase.market.requestStorage(purchase.request)
  except CatchableError as error:
    state.switch(PurchaseError(error: error))
    return

  state.switch(PurchaseSubmitted())
