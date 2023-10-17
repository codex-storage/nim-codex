import pkg/metrics
import pkg/chronicles
import ../statemachine
import ../../utils/exceptions

declareCounter(codexPurchasesError, "codex purchases error")

logScope:
    topics = "marketplace purchases errored"

type PurchaseErrored* = ref object of PurchaseState
  error*: ref CatchableError

method `$`*(state: PurchaseErrored): string =
  "errored"

method run*(state: PurchaseErrored, machine: Machine): Future[?State] {.async.} =
  codexPurchasesError.inc()
  let purchase = Purchase(machine)

  error "Purchasing error", error=state.error.msgDetail, requestId = purchase.requestId

  purchase.future.fail(state.error)
