import ../statemachine
import ../../asyncyeah

type PurchaseFinished* = ref object of PurchaseState

method `$`*(state: PurchaseFinished): string =
  "finished"

method run*(state: PurchaseFinished, machine: Machine): Future[?State] {.asyncyeah.} =
  let purchase = Purchase(machine)
  purchase.future.complete()
