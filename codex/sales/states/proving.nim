import pkg/chronicles
import ../statemachine
import ../salesagent
import ./errorhandling
import ./filling
import ./cancelled
import ./failed
import ./filled

logScope:
    topics = "marketplace sales proving"

type
  SaleProving* = ref object of ErrorHandlingState

method `$`*(state: SaleProving): string = "SaleProving"

method onCancelled*(state: SaleProving, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleProving, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(state: SaleProving, requestId: RequestId,
                     slotIndex: UInt256): ?State =
  return some State(SaleFilled())

method run*(state: SaleProving, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let context = SalesAgent(machine).context

  without request =? data.request:
    raiseAssert "no sale request"

  without onProve =? context.proving.onProve:
    raiseAssert "onProve callback not set"

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  debug "Start proof generation", requestId = $data.requestId
  let proof = await onProve(Slot(request: request, slotIndex: slotIndex))
  debug "Finished proof generation", requestId = $data.requestId

  return some State(SaleFilling(proof: proof))
