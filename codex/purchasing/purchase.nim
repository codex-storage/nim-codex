import ../market
import ../clock
import ./purchaseid

export purchaseid

type
  Purchase* = ref object
    future: Future[void]
    market: Market
    clock: Clock
    request*: StorageRequest

func newPurchase*(request: StorageRequest,
                  market: Market,
                  clock: Clock): Purchase =
  Purchase(request: request, market: market, clock: clock)

proc run(purchase: Purchase) {.async.} =
  let market = purchase.market
  let clock = purchase.clock

  proc requestStorage {.async.} =
    purchase.request = await market.requestStorage(purchase.request)

  proc waitUntilFulfilled {.async.} =
    let done = newFuture[void]()
    proc callback(_: RequestId) =
      done.complete()
    let request = purchase.request
    let subscription = await market.subscribeFulfillment(request.id, callback)
    await done
    await subscription.unsubscribe()

  proc withTimeout(future: Future[void]) {.async.} =
    let expiry = purchase.request.expiry.truncate(int64)
    await future.withTimeout(clock, expiry)

  await requestStorage()
  await waitUntilFulfilled().withTimeout()

proc start*(purchase: Purchase) =
  purchase.future = purchase.run()

proc wait*(purchase: Purchase) {.async.} =
  await purchase.future

func id*(purchase: Purchase): PurchaseId =
  PurchaseId(purchase.request.id)

func finished*(purchase: Purchase): bool =
  purchase.future.finished

func error*(purchase: Purchase): ?(ref CatchableError) =
  if purchase.future.failed:
    some purchase.future.error
  else:
    none (ref CatchableError)
