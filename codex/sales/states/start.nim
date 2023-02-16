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

# TODO: remove machine from this method, pass salesagent via constructor instead
method run*(state: SaleStart, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  await agent.retrieveRequest()
  # TODO: re-enable and fix this:
  # await agent.subscribeCancellation()
  # await agent.subscribeFailure()
  # await agent.subscribeSlotFilled()
  return some State(state.next)
