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

proc retrieveRequest(data: SalesData) {.async.} =
  if data.request.isNone:
    data.request = await data.sales.market.getRequest(data.requestId)

proc subscribeCancellation*(machine: Machine, data: SalesData) {.async.} =
  let market = data.sales.market

  proc onCancelled() {.async.} =
    let clock = data.sales.clock

    without request =? data.request:
      return

    await clock.waitUntil(request.expiry.truncate(int64))
    await data.fulfilled.unsubscribe()
    machine.schedule(cancelledEvent(request))

  data.cancelled = onCancelled()

  proc onFulfilled(_: RequestId) =
    data.cancelled.cancel()

  data.fulfilled =
    await market.subscribeFulfillment(data.requestId, onFulfilled)

proc asyncSpawn(future: Future[void], ignore: type CatchableError) =
  proc ignoringError {.async.} =
    try:
      await future
    except ignore:
      discard
  asyncSpawn ignoringError()

proc subscribeFailure*(machine: Machine, data: SalesData) {.async.} =
  let market = data.sales.market

  proc onFailed(_: RequestId) =
    without request =? data.request:
      return
    asyncSpawn data.failed.unsubscribe(), ignore = CatchableError
    machine.schedule(failedEvent(request))

  data.failed =
    await market.subscribeRequestFailed(data.requestId, onFailed)

proc subscribeSlotFilled*(machine: Machine, data: SalesData) {.async.} =
  let market = data.sales.market

  proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
    asyncSpawn data.slotFilled.unsubscribe(), ignore = CatchableError
    machine.schedule(slotFilledEvent(requestId, data.slotIndex))

  data.slotFilled =
    await market.subscribeSlotFilled(data.requestId,
                                     data.slotIndex,
                                     onSlotFilled)

method run*(state: SaleStart, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  await data.retrieveRequest()
  await machine.subscribeCancellation(data)
  await machine.subscribeFailure(data)
  await machine.subscribeSlotFilled(data)
  return some State(state.next)
