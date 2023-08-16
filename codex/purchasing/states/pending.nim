import pkg/metrics
import ../statemachine
import ./errorhandling
import ./submitted

declareCounter(codexPurchasesPending, "codex purchases pending")

type PurchasePending* = ref object of ErrorHandlingState

method `$`*(state: PurchasePending): string =
  "pending"

method run*(state: PurchasePending, machine: Machine): Future[?State] {.async.} =
  codexPurchasesPending.inc()
  let purchase = Purchase(machine)
  let request = !purchase.request
  await purchase.market.requestStorage(request)
  return some State(PurchaseSubmitted())
