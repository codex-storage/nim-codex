import ../statemachine
import ./error

type
  PurchaseFailed* = ref object of PurchaseState

method `$`*(state: PurchaseFailed): string =
  "failed"

method run*(state: PurchaseFailed, machine: Machine): Future[?State] {.async.} =
  let error = newException(PurchaseError, "Purchase failed")
  return some State(PurchaseErrored(error: error))
