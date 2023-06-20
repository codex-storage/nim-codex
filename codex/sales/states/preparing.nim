import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import ../../market
import ../salesagent
import ../statemachine
import ./errorhandling
import ./cancelled
import ./failed
import ./filled
import ./ignored
import ./downloading
import ./errored

type
  SalePreparing* = ref object of ErrorHandlingState
    availableSlotIndices*: seq[uint64]

logScope:
    topics = "sales preparing"

method `$`*(state: SalePreparing): string = "SalePreparing"

method onCancelled*(state: SalePreparing, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SalePreparing, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(state: SalePreparing, requestId: RequestId,
                     slotIndex: UInt256): ?State =
  return some State(SaleFilled())

method run*(state: SalePreparing, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let reservations = context.reservations

  await agent.retrieveRequest()

  if err =? (await agent.assignRandomSlotIndex(state.availableSlotIndices)).errorOption:
    if err of AllSlotsFilledError:
      return some State(SaleIgnored())
    return some State(SaleErrored(error: err))

  await agent.subscribe()

  without request =? data.request:
    raiseAssert "no sale request"

  without availability =? await reservations.find(
      request.ask.slotSize,
      request.ask.duration,
      request.ask.pricePerSlot,
      request.ask.collateral,
      used = false):
    info "no availability found for request, ignoring",
      slotSize = request.ask.slotSize,
      duration = request.ask.duration,
      pricePerSlot = request.ask.pricePerSlot,
      used = false
    return some State(SaleIgnored())

  return some State(SaleDownloading(availability: availability))
