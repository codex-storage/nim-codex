import pkg/metrics
import ../statemachine

declareCounter(codexPurchasesFinished, "codex purchases finished")

type PurchaseFinished* = ref object of PurchaseState

method `$`*(state: PurchaseFinished): string =
  "finished"

method run*(state: PurchaseFinished, machine: Machine): Future[?State] {.async.} =
  codexPurchasesFinished.inc()
  let purchase = Purchase(machine)
  purchase.future.complete()
