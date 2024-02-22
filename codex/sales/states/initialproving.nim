import pkg/questionable/results
import ../../clock
import ../../logutils
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
  let market = context.market
  let clock = context.clock

  without request =? data.request:
    raiseAssert "no sale request"

  without onProve =? context.onProve:
    raiseAssert "onProve callback not set"

  debug "Waiting until next period"
  let periodicity = await market.periodicity()
  let period = periodicity.periodOf(clock.now().u256)
  await clock.waitUntil(periodicity.periodEnd(period).truncate(int64) + 1)

  debug "Generating initial proof", requestId = data.requestId
  let
    slot = Slot(request: request, slotIndex: data.slotIndex)
    challenge = await context.market.getChallenge(slot.id)
  without proof =? (await onProve(slot, challenge)), err:
    error "Failed to generate initial proof", error = err.msg
    return some State(SaleErrored(error: err))

  debug "Finished proof calculation", requestId = data.requestId

  return some State(SaleFilling(proof: proof))
