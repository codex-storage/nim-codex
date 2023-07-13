import ../statemachine
import ../../asyncyeah

type PurchaseErrored* = ref object of PurchaseState
  error*: ref CatchableError

method `$`*(state: PurchaseErrored): string =
  "errored"

method run*(state: PurchaseErrored, machine: Machine): Future[?State] {.asyncyeah.} =
  let purchase = Purchase(machine)
  purchase.future.fail(state.error)
