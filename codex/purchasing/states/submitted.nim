import ../statemachine
import ./errorhandling
import ./started
import ./cancelled
import ../../asyncyeah

type PurchaseSubmitted* = ref object of ErrorHandlingState

method `$`*(state: PurchaseSubmitted): string =
  "submitted"

method run*(state: PurchaseSubmitted, machine: Machine): Future[?State] {.asyncyeah.} =
  let purchase = Purchase(machine)
  let request = !purchase.request
  let market = purchase.market
  let clock = purchase.clock

  proc wait {.asyncyeah.} =
    let done = newFuture[void]()
    proc callback(_: RequestId) =
      done.complete()
    let subscription = await market.subscribeFulfillment(request.id, callback)
    await done
    await subscription.unsubscribe()

  proc withTimeout(future: Future[void]) {.asyncyeah.} =
    let expiry = request.expiry.truncate(int64)
    await future.withTimeout(clock, expiry)

  try:
    await wait().withTimeout()
  except Timeout:
    return some State(PurchaseCancelled())

  return some State(PurchaseStarted())
