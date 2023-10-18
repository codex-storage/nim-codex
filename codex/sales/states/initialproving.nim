import pkg/chronicles
import ../statemachine
import ../salesagent
import ./errorhandling
import ./filling
import ./cancelled
import ./failed

logScope:
  topics = "marketplace sales initial-proving"

type
  SaleInitialProving* = ref object of ErrorHandlingState

method `$`*(state: SaleInitialProving): string = "SaleInitialProving"

method onCancelled*(state: SaleInitialProving, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleInitialProving, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(state: SaleInitialProving, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let context = SalesAgent(machine).context

  without request =? data.request:
    raiseAssert "no sale request"

  without onProve =? context.onProve:
    raiseAssert "onProve callback not set"

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  debug "Generating initial proof", requestId = $data.requestId
  let proof = await onProve(Slot(request: request, slotIndex: slotIndex))
  debug "Finished proof calculation", requestId = $data.requestId

  return some State(SaleFilling(proof: proof))
