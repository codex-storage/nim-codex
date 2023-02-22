import pkg/chronos
import pkg/upraises
import pkg/stint
import ./statemachine
import ../contracts/requests

proc newSalesAgent*(context: SalesContext,
                    requestId: RequestId,
                    slotIndex: UInt256,
                    availability: ?Availability,
                    request: ?StorageRequest): SalesAgent =
  SalesAgent(context: context, data: SalesData(
    requestId: requestId,
    availability: availability,
    slotIndex: slotIndex,
    request: request))

proc unsubscribe(data: SalesData) {.async.} =
  try:
    if not data.fulfilled.isNil:
      await data.fulfilled.unsubscribe()
  except CatchableError:
    discard
  try:
    if not data.failed.isNil:
      await data.failed.unsubscribe()
  except CatchableError:
    discard
  try:
    if not data.slotFilled.isNil:
      await data.slotFilled.unsubscribe()
  except CatchableError:
    discard
  if not data.cancelled.isNil:
    await data.cancelled.cancelAndWait()

proc stop*(agent: SalesAgent) {.async.} =
  procCall Machine(agent).stop()
  await agent.data.unsubscribe()
