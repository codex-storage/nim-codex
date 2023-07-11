import std/options
import pkg/chronicles
import ../../clock
import ../statemachine
import ../salesagent
import ../salescontext
import ./errorhandling
import ./cancelled
import ./failed
import ./errored
import ./payout

logScope:
    topics = "marketplace sales proving"

type
  SaleProving* = ref object of ErrorHandlingState
    loop: ?Future[void]

proc proveLoop(market: Market, clock: Clock, request: StorageRequest, slotIndex: UInt256, onProve: OnProve) {.async.} =
  proc getCurrentPeriod(): Future[Period] {.async.} =
    let periodicity = await market.periodicity()
    return periodicity.periodOf(clock.now().u256)

  proc waitUntilPeriod(period: Period) {.async.} =
    let periodicity = await market.periodicity()
    await clock.waitUntil(periodicity.periodStart(period).truncate(int64))

  let slot = Slot(request: request, slotIndex: slotIndex)
  let slotId = slot.id

  while true:
    let currentPeriod = await getCurrentPeriod()
    let slotState = await market.slotState(slot.id)
    if slotState == SlotState.Finished:
      debug "Slot reached finished state", period = currentPeriod, requestId = $request.id, slotIndex
      return

    debug "Proving for new period", period = currentPeriod, requestId = $request.id, slotIndex

    if (await market.isProofRequired(slotId)) or
       (await market.willProofBeRequired(slotId)):
      let proof = await onProve(slot)
      await market.submitProof(slotId, proof)

    await waitUntilPeriod(currentPeriod + 1)

method `$`*(state: SaleProving): string = "SaleProving"

method onCancelled*(state: SaleProving, request: StorageRequest): ?State =
  if loop =? state.loop:
      state.loop = Future[void].none
      if not loop.finished:
        loop.cancel()

  return some State(SaleCancelled())

method onFailed*(state: SaleProving, request: StorageRequest): ?State =
  if loop =? state.loop:
      state.loop = Future[void].none
      if not loop.finished:
        loop.cancel()

  return some State(SaleFailed())

method run*(state: SaleProving, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let context = SalesAgent(machine).context

  without request =? data.request:
    raiseAssert "no sale request"

  without onProve =? context.onProve:
    raiseAssert "onProve callback not set"

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  without market =? context.market:
    raiseAssert("market not set")

  without clock =? context.clock:
    raiseAssert("clock not set")

  debug "Start proving", requestId = $data.requestId, slotIndex
  try:
    let loop = proveLoop(market, clock, request, slotIndex, onProve)
    state.loop = some loop
    await loop
  except CancelledError:
    discard
  except CatchableError as e:
    error "Proving failed", msg = e.msg
    return some State(SaleErrored(error: e))

  debug "Stopping proving.", requestId = $data.requestId, slotIndex

  return some State(SalePayout())
