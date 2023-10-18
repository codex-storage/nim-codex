import pkg/chronicles
import ../../market
import ../statemachine
import ../salesagent
import ./errorhandling
import ./filled
import ./cancelled
import ./failed

logScope:
  topics = "marketplace sales filling"

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
  without (collateral =? data.request.?ask.?collateral):
    raiseAssert "Request not set"

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  debug "Filling slot", requestId = $data.requestId, slotIndex
  await market.fillSlot(data.requestId, slotIndex, state.proof, collateral)
