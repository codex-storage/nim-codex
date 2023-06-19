import ../statemachine
import ./errorhandling
import ./submitted

type PurchasePending* = ref object of ErrorHandlingState

method `$`*(state: PurchasePending): string =
  "pending"

method run*(state: PurchasePending, machine: Machine): Future[?State] {.async.} =
  let purchase = Purchase(machine)
  let request = !purchase.request
  await purchase.market.requestStorage(request)
  return some State(PurchaseSubmitted())
