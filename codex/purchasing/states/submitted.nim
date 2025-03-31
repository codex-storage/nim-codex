import pkg/metrics

import ../../logutils
import ../../utils/exceptions
import ../statemachine
import ./started
import ./cancelled
import ./error

logScope:
  topics = "marketplace purchases submitted"

declareCounter(codex_purchases_submitted, "codex purchases submitted")

type PurchaseSubmitted* = ref object of PurchaseState

method `$`*(state: PurchaseSubmitted): string =
  "submitted"

method run*(
    state: PurchaseSubmitted, machine: Machine
): Future[?State] {.async: (raises: []).} =
  codex_purchases_submitted.inc()
  let purchase = Purchase(machine)
  let request = !purchase.request
  let market = purchase.market
  let clock = purchase.clock

  info "Request submitted, waiting for slots to be filled",
    requestId = purchase.requestId

  proc wait() {.async.} =
    let done = newFuture[void]()
    proc callback(_: RequestId) =
      done.complete()

    let subscription = await market.subscribeFulfillment(request.id, callback)
    await done
    await subscription.unsubscribe()

  proc withTimeout(future: Future[void]) {.async.} =
    let expiry = (await market.requestExpiresAt(request.id)) + 1'u8
    trace "waiting for request fulfillment or expiry", expiry
    await future.withTimeout(clock, expiry.toSecondsSince1970)

  try:
    await wait().withTimeout()
  except Timeout:
    return some State(PurchaseCancelled())
  except CancelledError as e:
    trace "PurchaseSubmitted.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during PurchaseSubmitted.run", error = e.msgDetail
    return some State(PurchaseErrored(error: e))

  return some State(PurchaseStarted())
