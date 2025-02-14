import pkg/metrics

import ../statemachine
import ../../utils/exceptions
import ../../logutils
import ./error

declareCounter(codex_purchases_finished, "codex purchases finished")

logScope:
  topics = "marketplace purchases finished"

type PurchaseFinished* = ref object of PurchaseState

method `$`*(state: PurchaseFinished): string =
  "finished"

method run*(
    state: PurchaseFinished, machine: Machine
): Future[?State] {.async: (raises: []).} =
  codex_purchases_finished.inc()
  let purchase = Purchase(machine)
  try:
    info "Purchase finished, withdrawing remaining funds",
      requestId = purchase.requestId
    await purchase.market.withdrawFunds(purchase.requestId)

    purchase.future.complete()
  except CancelledError as e:
    trace "PurchaseFinished.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during PurchaseFinished.run", error = e.msgDetail
    return some State(PurchaseErrored(error: e))
