import ../../logutils
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
    proof*: Groth16Proof

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

  debug "Filling slot", requestId = data.requestId, slotIndex = data.slotIndex
  await market.fillSlot(data.requestId, data.slotIndex, state.proof, collateral)
  debug "Waiting for slot filled event...", requestId = $data.requestId, slotIndex = $data.slotIndex
