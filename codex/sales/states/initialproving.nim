import pkg/chronicles
import pkg/questionable/results
import ../statemachine
import ../salesagent
import ./errorhandling
import ./filling
import ./cancelled
import ./errored
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

  debug "Generating initial proof", requestId = $data.requestId
  let
    slot = Slot(request: request, slotIndex: data.slotIndex)
    challenge = await context.market.getChallenge(slot.id)
  without proof =? (await onProve(slot, challenge)), err:
    error "Failed to generate initial proof", error = err.msg
    return some State(SaleErrored(error: err))

  debug "Finished proof calculation", requestId = $data.requestId

  return some State(SaleFilling(proof: proof))
