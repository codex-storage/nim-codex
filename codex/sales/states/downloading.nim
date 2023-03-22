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
import ./proving
import ./errored

type
  SaleDownloading* = ref object of ErrorHandlingState
    failedSubscription: ?market.Subscription
    hasCancelled: ?Future[void]

method `$`*(state: SaleDownloading): string = "SaleDownloading"

method onCancelled*(state: SaleDownloading, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleDownloading, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(state: SaleDownloading, requestId: RequestId,
                     slotIndex: UInt256): ?State =
  return some State(SaleFilled())

method run*(state: SaleDownloading, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context

  await agent.retrieveRequest()
  await agent.subscribe()

  without onStore =? context.onStore:
    raiseAssert "onStore callback not set"

  without request =? data.request:
    raiseAssert "no sale request"

  without availability =? await context.reservations.find(
      request.ask.slotSize,
      request.ask.duration,
      request.ask.pricePerSlot,
      used = false):
    info "no availability found for request, ignoring",
      slotSize = request.ask.slotSize,
      duration = request.ask.duration,
      pricePerSlot = request.ask.pricePerSlot,
      used = false
    return

  data.availability = some availability

  if err =? (await agent.context.reservations.markUsed(
    availability,
    request.slotId(data.slotIndex))).errorOption:
    let error = newException(AvailabilityUpdateError,
      "failed to mark availability as used")
    error.parent = err
    return some State(SaleErrored(error: error))

  await onStore(request, data.slotIndex, data.availability)
  return some State(SaleProving())
