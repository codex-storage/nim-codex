import ../statemachine
import ./error
import ../../asyncyeah

type
  PurchaseFailed* = ref object of PurchaseState

method `$`*(state: PurchaseFailed): string =
  "failed"

method run*(state: PurchaseFailed, machine: Machine): Future[?State] {.asyncyeah.} =
  let error = newException(PurchaseError, "Purchase failed")
  return some State(PurchaseErrored(error: error))
