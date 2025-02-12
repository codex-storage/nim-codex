import pkg/metrics

import ../../logutils
import ../../utils/exceptions
import ../statemachine
import ./errorhandling
import ./error

declareCounter(codex_purchases_cancelled, "codex purchases cancelled")

logScope:
  topics = "marketplace purchases cancelled"

type PurchaseCancelled* = ref object of ErrorHandlingState

method `$`*(state: PurchaseCancelled): string =
  "cancelled"

method run*(
    state: PurchaseCancelled, machine: Machine
): Future[?State] {.async: (raises: []).} =
  codex_purchases_cancelled.inc()
  let purchase = Purchase(machine)

  try:
    warn "Request cancelled, withdrawing remaining funds",
      requestId = purchase.requestId
    await purchase.market.withdrawFunds(purchase.requestId)

    let error = newException(Timeout, "Purchase cancelled due to timeout")
    purchase.future.fail(error)
  except CancelledError as e:
    trace "PurchaseCancelled.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during PurchaseCancelled.run", error = e.msgDetail
    return some State(PurchaseErrored(error: e))
