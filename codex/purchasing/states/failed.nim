import ../statemachine
import ./error

type
  PurchaseFailed* = ref object of PurchaseState

method enter*(state: PurchaseFailed) =
  let error = newException(PurchaseError, "Purchase failed")
  state.switch(PurchaseErrored(error: error))
