import ../statemachine
import ./error
import ./finished

type PurchaseStarted* = ref object of PurchaseState

method enterAsync*(state: PurchaseStarted) {.async.} =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  let clock = purchase.clock
  let market = purchase.market
  let request = purchase.request

  try:
    await clock.waitUntil(await market.getRequestEnd(request.id))
  except CatchableError as error:
    state.switch(PurchaseError(error: error))

  state.switch(PurchaseFinished())
