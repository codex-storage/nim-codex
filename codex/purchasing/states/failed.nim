import pkg/metrics
import ../statemachine
import ./error

declareCounter(codexPurchasesFailed, "codex purchases failed")

type
  PurchaseFailed* = ref object of PurchaseState

method `$`*(state: PurchaseFailed): string =
  "failed"

method run*(state: PurchaseFailed, machine: Machine): Future[?State] {.async.} =
  codexPurchasesFailed.inc()
  let error = newException(PurchaseError, "Purchase failed")
  return some State(PurchaseErrored(error: error))
