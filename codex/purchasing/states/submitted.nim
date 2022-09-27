import ../statemachine
import ./error
import ./started
import ./cancelled

type PurchaseSubmitted* = ref object of PurchaseState

method enterAsync(state: PurchaseSubmitted) {.async.} =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  let market = purchase.market
  let clock = purchase.clock

  proc wait {.async.} =
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

  try:
    await wait().withTimeout()
  except Timeout:
    state.switch(PurchaseCancelled())
    return
  except CatchableError as error:
    state.switch(PurchaseError(error: error))
    return

  state.switch(PurchaseStarted())
