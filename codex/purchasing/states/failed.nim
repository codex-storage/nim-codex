import pkg/metrics
import ../statemachine
import ./error

declareCounter(codex_purchases_failed, "codex purchases failed")

type
  PurchaseFailed* = ref object of PurchaseState

method `$`*(state: PurchaseFailed): string =
  "failed"

method run*(state: PurchaseFailed, machine: Machine): Future[?State] {.async.} =
  codex_purchases_failed.inc()
  let error = newException(PurchaseError, "Purchase failed")
  return some State(PurchaseErrored(error: error))
