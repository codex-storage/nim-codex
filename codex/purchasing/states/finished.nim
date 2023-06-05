import ../statemachine

type PurchaseFinished* = ref object of PurchaseState

method `$`*(state: PurchaseFinished): string =
  "finished"

method run*(state: PurchaseFinished, machine: Machine): Future[?State] {.async.} =
  let purchase = Purchase(machine)
  purchase.future.complete()
