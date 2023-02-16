import pkg/chronos
import pkg/upraises
import pkg/stint
import ./statemachine
import ../contracts/requests

proc newSalesAgent*(sales: Sales,
                    requestId: RequestId,
                    slotIndex: UInt256,
                    availability: ?Availability,
                    request: ?StorageRequest): SalesAgent =
  SalesAgent(
    sales: sales,
    requestId: requestId,
    availability: availability,
    slotIndex: slotIndex,
    request: request)

# proc subscribeCancellation*(agent: SalesAgent): Future[void] {.gcsafe.}
# proc subscribeFailure*(agent: SalesAgent): Future[void] {.gcsafe.}
# proc subscribeSlotFilled*(agent: SalesAgent): Future[void] {.gcsafe.}

proc stop*(agent: SalesAgent) {.async.} =
  try:
    await agent.fulfilled.unsubscribe()
  except CatchableError:
    discard
  try:
    await agent.failed.unsubscribe()
  except CatchableError:
    discard
  try:
    await agent.slotFilled.unsubscribe()
  except CatchableError:
    discard
  if not agent.cancelled.completed:
    await agent.cancelled.cancelAndWait()

proc subscribeCancellation*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onCancelled() {.async.} =
    let clock = agent.sales.clock

    without request =? agent.request:
      return

    await clock.waitUntil(request.expiry.truncate(int64))
    await agent.fulfilled.unsubscribe()
    agent.schedule(cancelledEvent(request))

  agent.cancelled = onCancelled()

  proc onFulfilled(_: RequestId) =
    agent.cancelled.cancel()

  agent.fulfilled =
    await market.subscribeFulfillment(agent.requestId, onFulfilled)

# TODO: move elsewhere
proc asyncSpawn(future: Future[void], ignore: type CatchableError) =
  proc ignoringError {.async.} =
    try:
      await future
    except ignore:
      discard
  asyncSpawn ignoringError()

proc subscribeFailure*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onFailed(_: RequestId) =
    without request =? agent.request:
      return
    asyncSpawn agent.failed.unsubscribe(), ignore = CatchableError
    agent.schedule(failedEvent(request))

  agent.failed =
    await market.subscribeRequestFailed(agent.requestId, onFailed)

proc subscribeSlotFilled*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
    asyncSpawn agent.slotFilled.unsubscribe(), ignore = CatchableError
    agent.schedule(slotFilledEvent(requestId, agent.slotIndex))

  agent.slotFilled =
    await market.subscribeSlotFilled(agent.requestId,
                                     agent.slotIndex,
                                     onSlotFilled)
