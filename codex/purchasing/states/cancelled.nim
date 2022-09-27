import ../statemachine
import ./error

type PurchaseCancelled* = ref object of PurchaseState

method enterAsync*(state: PurchaseCancelled) {.async.} =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  try:
    await purchase.market.withdrawFunds(purchase.request.id)
  except CatchableError as error:
    state.switch(PurchaseError(error: error))
    return

  let error = newException(Timeout, "Purchase cancelled due to timeout")
  state.switch(PurchaseError(error: error))
