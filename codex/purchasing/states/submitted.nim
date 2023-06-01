import ../statemachine
import ./error
import ./started
import ./cancelled

type PurchaseSubmitted* = ref object of PurchaseState

method `$`*(state: PurchaseSubmitted): string =
  "submitted"

method run*(state: PurchaseSubmitted, machine: Machine): Future[?State] {.async.} =
  let purchase = Purchase(machine)
  let request = !purchase.request
  let market = purchase.market
  let clock = purchase.clock

  proc wait {.async.} =
    let done = newFuture[void]()
    proc callback(_: RequestId) =
      done.complete()
    let subscription = await market.subscribeFulfillment(request.id, callback)
    await done
    await subscription.unsubscribe()

  proc withTimeout(future: Future[void]) {.async.} =
    let expiry = request.expiry.truncate(int64)
    await future.withTimeout(clock, expiry)

  try:
    await wait().withTimeout()
  except Timeout:
    return some State(PurchaseCancelled())

  return some State(PurchaseStarted())

method onError*(state: PurchaseSubmitted, error: ref CatchableError): ?State =
  return some State(PurchaseErrored(error: error))
