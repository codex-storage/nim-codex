import pkg/chronos
import pkg/upraises
import pkg/stint
import ./statemachine
import ../contracts/requests
import ./salescontext
import ./salesdata
import ./availability

type SalesAgent* = ref object of Machine
  context*: SalesContext
  data*: SalesData

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

proc stop*(agent: SalesAgent) {.async.} =
  procCall Machine(agent).stop()
  await agent.data.unsubscribe()
