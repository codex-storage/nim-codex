import ../statemachine
import ./error

type
  PurchaseFailed* = ref object of PurchaseState
  PurchaseFailedError* = object of CatchableError

method enter*(state: PurchaseFailed) =
  let error = newException(PurchaseFailedError, "Purchase failed")
  state.switch(PurchaseError(error: error))
