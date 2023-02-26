import pkg/chronos
import pkg/upraises
import pkg/stint
import ./statemachine
import ../contracts/requests

# TODO: move elsewhere
proc asyncSpawn(future: Future[void], ignore: type CatchableError) =
  proc ignoringError {.async.} =
    try:
      await future
    except ignore:
      discard
  asyncSpawn ignoringError()

proc subscribeCancellation*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onCancelled() {.async.} =
    let clock = agent.sales.clock
    without request =? agent.request:
      return

    await clock.waitUntil(request.expiry.truncate(int64))
    asyncSpawn agent.subscribeFulfilled.unsubscribe(), ignore = CatchableError
    agent.requestState.setValue(RequestState.Cancelled)

  proc onFulfilled(_: RequestId) =
    agent.waitForCancelled.cancel()

  agent.subscribeFulfilled =
    await market.subscribeFulfillment(agent.requestId, onFulfilled)

  agent.waitForCancelled = onCancelled()

proc subscribeFailure*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onFailed(_: RequestId) {.upraises:[], gcsafe.} =
    asyncSpawn agent.subscribeFailed.unsubscribe(), ignore = CatchableError
    try:
      agent.requestState.setValue(RequestState.Failed)
    except AsyncQueueFullError as e:
      raiseAssert "State machine critical failure: " & e.msg

  agent.subscribeFailed =
    await market.subscribeRequestFailed(agent.requestId, onFailed)

proc subscribeSlotFill*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onSlotFilled(
    requestId: RequestId,
    slotIndex: UInt256) {.upraises:[], gcsafe.} =

    let market = agent.sales.market

    asyncSpawn agent.subscribeSlotFilled.unsubscribe(), ignore = CatchableError
    try:
      agent.slotState.setValue(SlotState.Filled)
    except AsyncQueueFullError as e:
      raiseAssert "State machine critical failure: " & e.msg

  agent.subscribeSlotFilled =
    await market.subscribeSlotFilled(agent.requestId,
                                    agent.slotIndex,
                                    onSlotFilled)

proc subscribe*(agent: SalesAgent) {.async.} =
  # TODO: Check that the subscription handlers aren't already assigned before
  # assigning. This will allow for agent.subscribe to be called multiple times
  await agent.subscribeCancellation()
  await agent.subscribeFailure()
  await agent.subscribeSlotFill()

proc unsubscribe*(agent: SalesAgent) {.async.} =
  try:
    await agent.subscribeFulfilled.unsubscribe()
  except CatchableError:
    discard
  try:
    await agent.subscribeFailed.unsubscribe()
  except CatchableError:
    discard
  try:
    await agent.subscribeSlotFilled.unsubscribe()
  except CatchableError:
    discard
  if not agent.waitForCancelled.completed:
    await agent.waitForCancelled.cancelAndWait()

  procCall Machine(agent).stop()
