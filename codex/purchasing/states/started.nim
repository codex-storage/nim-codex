import ../statemachine
import ./errorhandling
import ./finished
import ./failed
import ../../asyncyeah

type PurchaseStarted* = ref object of ErrorHandlingState

method `$`*(state: PurchaseStarted): string =
  "started"

method run*(state: PurchaseStarted, machine: Machine): Future[?State] {.asyncyeah.} =
  let purchase = Purchase(machine)

  let clock = purchase.clock
  let market = purchase.market

  let failed = newFuture[void]()
  proc callback(_: RequestId) =
    failed.complete()
  let subscription = await market.subscribeRequestFailed(purchase.requestId, callback)

  let ended = clock.waitUntil(await market.getRequestEnd(purchase.requestId))
  let fut = await one(ended, failed)
  await subscription.unsubscribe()
  if fut.id == failed.id:
    ended.cancel()
    return some State(PurchaseFailed())
  else:
    failed.cancel()
    return some State(PurchaseFinished())
