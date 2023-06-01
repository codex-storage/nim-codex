import ../statemachine
import ./error

type PurchaseCancelled* = ref object of PurchaseState

method `$`*(state: PurchaseCancelled): string =
  "cancelled"

method run*(state: PurchaseCancelled, machine: Machine): Future[?State] {.async.} =
  let purchase = Purchase(machine)
  await purchase.market.withdrawFunds(purchase.requestId)
  let error = newException(Timeout, "Purchase cancelled due to timeout")
  return some State(PurchaseErrored(error: error))

method onError*(state: PurchaseCancelled, error: ref CatchableError): ?State =
  return some State(PurchaseErrored(error: error))
