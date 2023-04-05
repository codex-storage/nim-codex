import ../../market
import ../statemachine
import ../salesagent
import ./errorhandling
import ./filled
import ./cancelled
import ./failed

type
  SaleFilling* = ref object of ErrorHandlingState
    proof*: seq[byte]

method `$`*(state: SaleFilling): string = "SaleFilling"

method onCancelled*(state: SaleFilling, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilling, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(state: SaleFilling, requestId: RequestId,
                     slotIndex: UInt256): ?State =
  return some State(SaleFilled())

method run(state: SaleFilling, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let market = SalesAgent(machine).context.market

  await market.fillSlot(data.requestId, data.slotIndex, state.proof, data.ask.collateral)
