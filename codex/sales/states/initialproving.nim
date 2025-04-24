import pkg/questionable/results
import ../../clock
import ../../logutils
import ../../utils/exceptions
import ../statemachine
import ../salesagent
import ./filling
import ./cancelled
import ./errored
import ./failed

logScope:
  topics = "marketplace sales initial-proving"

type SaleInitialProving* = ref object of SaleState

method `$`*(state: SaleInitialProving): string =
  "SaleInitialProving"

method onCancelled*(state: SaleInitialProving, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleInitialProving, request: StorageRequest): ?State =
  return some State(SaleFailed())

proc waitUntilNextPeriod(clock: Clock, periodicity: Periodicity) {.async.} =
  trace "Waiting until next period"
  let period = periodicity.periodOf(clock.now().Timestamp)
  let periodEnd = periodicity.periodEnd(period)
  await clock.waitUntil((periodEnd + 1).toSecondsSince1970)

proc waitForStableChallenge(market: Market, clock: Clock, slotId: SlotId) {.async.} =
  let periodicity = await market.periodicity()
  let downtime = await market.proofDowntime()
  await clock.waitUntilNextPeriod(periodicity)
  while (await market.getPointer(slotId)) > (256 - downtime):
    await clock.waitUntilNextPeriod(periodicity)

method run*(
    state: SaleInitialProving, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let data = SalesAgent(machine).data
  let context = SalesAgent(machine).context
  let market = context.market
  let clock = context.clock

  without request =? data.request:
    raiseAssert "no sale request"

  without onProve =? context.onProve:
    raiseAssert "onProve callback not set"

  try:
    debug "Waiting for a proof challenge that is valid for the entire period"
    let slot = Slot(request: request, slotIndex: data.slotIndex)
    await waitForStableChallenge(market, clock, slot.id)

    debug "Generating initial proof", requestId = data.requestId, slotIndex = data.slotIndex
    let challenge = await context.market.getChallenge(slot.id)
    without proof =? (await onProve(slot, challenge)), err:
      error "Failed to generate initial proof", error = err.msg
      return some State(SaleErrored(error: err))

    debug "Finished proof calculation", requestId = data.requestId, slotIndex = data.slotIndex

    return some State(SaleFilling(proof: proof))
  except CancelledError as e:
    trace "SaleInitialProving.run onCleanUp was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleInitialProving.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
