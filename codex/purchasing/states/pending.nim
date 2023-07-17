import ../statemachine
import ./errorhandling
import ./submitted
import ../../asyncyeah

type PurchasePending* = ref object of ErrorHandlingState

method `$`*(state: PurchasePending): string =
  "pending"

method run*(state: PurchasePending, machine: Machine): Future[?State] {.asyncyeah.} =
  let purchase = Purchase(machine)
  let request = !purchase.request
  await purchase.market.requestStorage(request)
  return some State(PurchaseSubmitted())
