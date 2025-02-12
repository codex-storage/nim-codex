import pkg/metrics
import ../../logutils
import ../../utils/exceptions
import ../statemachine
import ./errorhandling
import ./submitted
import ./error

declareCounter(codex_purchases_pending, "codex purchases pending")

type PurchasePending* = ref object of ErrorHandlingState

method `$`*(state: PurchasePending): string =
  "pending"

method run*(
    state: PurchasePending, machine: Machine
): Future[?State] {.async: (raises: []).} =
  codex_purchases_pending.inc()
  let purchase = Purchase(machine)
  try:
    let request = !purchase.request
    await purchase.market.requestStorage(request)
    return some State(PurchaseSubmitted())
  except CancelledError as e:
    trace "PurchasePending.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during PurchasePending.run", error = e.msgDetail
    return some State(PurchaseErrored(error: e))
