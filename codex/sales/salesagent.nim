import pkg/chronos
import pkg/chronicles
import pkg/stint
import ../contracts/requests
import ../utils/asyncspawn
import ./statemachine
import ./salescontext
import ./salesdata
import ./reservations

export reservations

logScope:
  topics = "marketplace sales"

type SalesAgent* = ref object of Machine
  context*: SalesContext
  data*: SalesData
  subscribed: bool

func `==`*(a, b: SalesAgent): bool =
  a.data.requestId == b.data.requestId and
  a.data.slotIndex == b.data.slotIndex

proc newSalesAgent*(context: SalesContext,
                    requestId: RequestId,
                    slotIndex: UInt256,
                    request: ?StorageRequest): SalesAgent =
  SalesAgent(
    context: context,
    data: SalesData(
      requestId: requestId,
      slotIndex: slotIndex,
      request: request))

proc retrieveRequest*(agent: SalesAgent) {.async.} =
  let data = agent.data
  let market = agent.context.market
  if data.request.isNone:
    data.request = await market.getRequest(data.requestId)

proc subscribeCancellation(agent: SalesAgent) {.async.} =
  let data = agent.data
  let market = agent.context.market
  let clock = agent.context.clock

  proc onCancelled() {.async.} =
    without request =? data.request:
      return

    await clock.waitUntil(request.expiry.truncate(int64))
    if not data.fulfilled.isNil:
      asyncSpawn data.fulfilled.unsubscribe(), ignore = CatchableError
    agent.schedule(cancelledEvent(request))

  data.cancelled = onCancelled()

  proc onFulfilled(_: RequestId) =
    data.cancelled.cancel()

  data.fulfilled =
    await market.subscribeFulfillment(data.requestId, onFulfilled)

proc subscribeFailure(agent: SalesAgent) {.async.} =
  let data = agent.data
  let market = agent.context.market

  proc onFailed(_: RequestId) =
    without request =? data.request:
      return
    asyncSpawn data.failed.unsubscribe(), ignore = CatchableError
    agent.schedule(failedEvent(request))

  data.failed =
    await market.subscribeRequestFailed(data.requestId, onFailed)

proc subscribeSlotFilled(agent: SalesAgent) {.async.} =
  let data = agent.data
  let market = agent.context.market

  proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
    asyncSpawn data.slotFilled.unsubscribe(), ignore = CatchableError
    agent.schedule(slotFilledEvent(requestId, data.slotIndex))

  data.slotFilled =
    await market.subscribeSlotFilled(data.requestId,
                                     data.slotIndex,
                                     onSlotFilled)

proc subscribe*(agent: SalesAgent) {.async.} =
  if agent.subscribed:
    return

  await agent.subscribeCancellation()
  await agent.subscribeFailure()
  await agent.subscribeSlotFilled()
  agent.subscribed = true

proc unsubscribe*(agent: SalesAgent) {.async.} =
  if not agent.subscribed:
    return

  let data = agent.data
  try:
    if not data.fulfilled.isNil:
      await data.fulfilled.unsubscribe()
      data.fulfilled = nil
  except CatchableError:
    discard
  try:
    if not data.failed.isNil:
      await data.failed.unsubscribe()
      data.failed = nil
  except CatchableError:
    discard
  try:
    if not data.slotFilled.isNil:
      await data.slotFilled.unsubscribe()
      data.slotFilled = nil
  except CatchableError:
    discard
  if not data.cancelled.isNil:
    await data.cancelled.cancelAndWait()
    data.cancelled = nil

  agent.subscribed = false

proc stop*(agent: SalesAgent) {.async.} =
  procCall Machine(agent).stop()
  await agent.unsubscribe()
