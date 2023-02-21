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

proc stop*(agent: SalesAgent) {.async.} =
  procCall Machine(agent).stop()
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
