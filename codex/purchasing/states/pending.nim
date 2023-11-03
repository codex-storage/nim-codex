import pkg/metrics
import ../statemachine
import ./errorhandling
import ./submitted

declareCounter(codex_purchases_pending, "codex purchases pending")

type PurchasePending* = ref object of ErrorHandlingState

method `$`*(state: PurchasePending): string =
  "pending"

method run*(state: PurchasePending, machine: Machine): Future[?State] {.async.} =
  codex_purchases_pending.inc()
  let purchase = Purchase(machine)
  let request = !purchase.request
  await purchase.market.requestStorage(request)
  return some State(PurchaseSubmitted())
