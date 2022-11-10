import ../statemachine
import ./error
import ./finished
import ./failed

type PurchaseStarted* = ref object of PurchaseState

method enterAsync*(state: PurchaseStarted) {.async.} =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  let clock = purchase.clock
  let market = purchase.market

  let failed = newFuture[void]()
  proc callback(_: RequestId) {.async.} =
    failed.complete()
  let subscription = await market.subscribeRequestFailed(purchase.requestId, callback)

  let ended = clock.waitUntil(await market.getRequestEnd(purchase.requestId))
  try:
    let fut = await one(ended, failed)
    if fut.id == failed.id:
      ended.cancel()
      state.switch(PurchaseFailed())
    else:
      failed.cancel()
      state.switch(PurchaseFinished())
    await subscription.unsubscribe()
  except CatchableError as error:
    state.switch(PurchaseErrored(error: error))

method description*(state: PurchaseStarted): string =
  "started"
