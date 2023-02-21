import ./downloading
import ./cancelled
import ./failed
import ./filled
import ../statemachine

type
  SaleStart* = ref object of SaleState
    next*: SaleState

method `$`*(state: SaleStart): string = "SaleStart"

method onCancelled*(state: SaleStart, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleStart, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(state: SaleStart, requestId: RequestId,
                     slotIndex: UInt256): ?State =
  return some State(SaleFilled())

proc retrieveRequest(agent: SalesAgent) {.async.} =
  if agent.request.isNone:
    agent.request = await agent.sales.market.getRequest(agent.requestId)

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

method run*(state: SaleStart, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  await agent.retrieveRequest()
  await agent.subscribeCancellation()
  await agent.subscribeFailure()
  await agent.subscribeSlotFilled()
  return some State(state.next)
