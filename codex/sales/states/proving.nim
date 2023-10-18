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
  SlotNotFilledError* = object of CatchableError
  SaleProving* = ref object of ErrorHandlingState
    loop: Future[void]

method prove*(
  state: SaleProving,
  slot: Slot,
  onProve: OnProve,
  market: Market,
  currentPeriod: Period
) {.base, async.} =
  try:
    let proof = await onProve(slot)
    debug "Submitting proof", currentPeriod = currentPeriod, slotId = $slot.id
    await market.submitProof(slot.id, proof)
  except CatchableError as e:
    error "Submitting proof failed", msg = e.msg

proc proveLoop(
  state: SaleProving,
  market: Market,
  clock: Clock,
  request: StorageRequest,
  slotIndex: UInt256,
  onProve: OnProve
) {.async.} =

  let slot = Slot(request: request, slotIndex: slotIndex)
  let slotId = slot.id

  logScope:
    period = currentPeriod
    requestId = $request.id
    slotIndex
    slotId = $slot.id

  proc getCurrentPeriod(): Future[Period] {.async.} =
    let periodicity = await market.periodicity()
    return periodicity.periodOf(clock.now().u256)

  proc waitUntilPeriod(period: Period) {.async.} =
    let periodicity = await market.periodicity()
    await clock.waitUntil(periodicity.periodStart(period).truncate(int64))

  while true:
    let currentPeriod = await getCurrentPeriod()
    let slotState = await market.slotState(slot.id)
    if slotState == SlotState.Finished:
      debug "Slot reached finished state", period = currentPeriod
      return

    if slotState != SlotState.Filled:
      raise newException(SlotNotFilledError, "Slot is not in Filled state!")

    debug "Proving for new period", period = currentPeriod

    if (await market.isProofRequired(slotId)) or (await market.willProofBeRequired(slotId)):
      debug "Proof is required", period = currentPeriod
      await state.prove(slot, onProve, market, currentPeriod)

    await waitUntilPeriod(currentPeriod + 1)

method `$`*(state: SaleProving): string = "SaleProving"

method onCancelled*(state: SaleProving, request: StorageRequest): ?State =
  if not state.loop.isNil:
    if not state.loop.finished:
      try:
        waitFor state.loop.cancelAndWait()
      except CatchableError as e:
        error "Error during cancelation of prooving loop", msg = e.msg

    state.loop = nil

  return some State(SaleCancelled())

method onFailed*(state: SaleProving, request: StorageRequest): ?State =
  if not state.loop.isNil:
    if not state.loop.finished:
      try:
        waitFor state.loop.cancelAndWait()
      except CatchableError as e:
        error "Error during cancelation of prooving loop", msg = e.msg

    state.loop = nil

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
    let loop = state.proveLoop(market, clock, request, slotIndex, onProve)
    state.loop = loop
    await loop
  except CancelledError:
    discard
  except CatchableError as e:
    error "Proving failed", msg = e.msg
    return some State(SaleErrored(error: e))
  finally:
    # Cleanup of the proving loop
    debug "Stopping proving.", requestId = $data.requestId, slotIndex

    if not state.loop.isNil:
        if not state.loop.finished:
          try:
            await state.loop.cancelAndWait()
          except CatchableError as e:
            error "Error during cancelation of prooving loop", msg = e.msg

        state.loop = nil

  return some State(SalePayout())
