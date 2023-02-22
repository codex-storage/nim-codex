import ../statemachine
import ../salesdata
import ../salesagent
import ./downloading
import ./cancelled
import ./failed
import ./filled

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

method run*(state: SaleStart, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  await agent.retrieveRequest()
  await agent.subscribe()
  return some State(state.next)
