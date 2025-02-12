import pkg/metrics
import ../statemachine
import ../../logutils
import ../../utils/exceptions
import ./error

declareCounter(codex_purchases_failed, "codex purchases failed")

type PurchaseFailed* = ref object of PurchaseState

method `$`*(state: PurchaseFailed): string =
  "failed"

method run*(state: PurchaseFailed, machine: Machine): Future[?State] {.async: (raises: []).} =
  codex_purchases_failed.inc()
  let purchase = Purchase(machine)

  try:
    warn "Request failed, withdrawing remaining funds", requestId = purchase.requestId
    await purchase.market.withdrawFunds(purchase.requestId)
  except CancelledError as e:
    trace "PurchaseFailed.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during PurchaseFailed.run", error = e.msgDetail
    return some State(PurchaseErrored(error: e))

  let error = newException(PurchaseError, "Purchase failed")
  return some State(PurchaseErrored(error: error))
