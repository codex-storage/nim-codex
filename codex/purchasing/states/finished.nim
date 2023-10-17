import pkg/metrics
import pkg/chronicles
import ../statemachine

declareCounter(codexPurchasesFinished, "codex purchases finished")

logScope:
    topics = "marketplace purchases finished"

type PurchaseFinished* = ref object of PurchaseState

method `$`*(state: PurchaseFinished): string =
  "finished"

method run*(state: PurchaseFinished, machine: Machine): Future[?State] {.async.} =
  codexPurchasesFinished.inc()
  let purchase = Purchase(machine)
  info "Purchase finished", requestId = purchase.requestId
  purchase.future.complete()
