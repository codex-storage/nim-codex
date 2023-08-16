import pkg/metrics
import ../statemachine

declareCounter(codexPurchasesError, "codex purchases error")

type PurchaseErrored* = ref object of PurchaseState
  error*: ref CatchableError

method `$`*(state: PurchaseErrored): string =
  "errored"

method run*(state: PurchaseErrored, machine: Machine): Future[?State] {.async.} =
  codexPurchasesError.inc()
  let purchase = Purchase(machine)
  purchase.future.fail(state.error)
