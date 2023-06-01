import ../statemachine
import ./submitted
import ./error

type PurchasePending* = ref object of PurchaseState

method `$`*(state: PurchasePending): string =
  "pending"

method run*(state: PurchasePending, machine: Machine): Future[?State] {.async.} =
  let purchase = Purchase(machine)
  let request = !purchase.request
  await purchase.market.requestStorage(request)
  return some State(PurchaseSubmitted())

method onError*(state: PurchasePending, error: ref CatchableError): ?State =
  return some State(PurchaseErrored(error: error))
