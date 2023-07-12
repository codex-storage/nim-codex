import pkg/metrics
import ../statemachine
import ./errorhandling
import ./error

declareCounter(codexPurchasesCancelled, "codex purchases cancelled")

type PurchaseCancelled* = ref object of ErrorHandlingState

method `$`*(state: PurchaseCancelled): string =
  "cancelled"

method run*(state: PurchaseCancelled, machine: Machine): Future[?State] {.async.} =
  codexPurchasesCancelled.inc()
  let purchase = Purchase(machine)
  await purchase.market.withdrawFunds(purchase.requestId)
  let error = newException(Timeout, "Purchase cancelled due to timeout")
  return some State(PurchaseErrored(error: error))
