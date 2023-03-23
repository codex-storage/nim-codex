import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import ../../blocktype as bt
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
  let reservations = context.reservations

  await agent.retrieveRequest()
  await agent.subscribe()

  without onStore =? context.onStore:
    raiseAssert "onStore callback not set"

  without request =? data.request:
    raiseAssert "no sale request"

  without availability =? await reservations.find(
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

  # mark availability as used so that it is not matched to other requests
  if err =? (await reservations.markUsed(availability.id)).errorOption:
    return some State(SaleErrored(error: err))

  proc onBatch(blocks: seq[bt.Block]) {.async.} =
    # release batches of blocks as they are written to disk and
    # update availability size
    var bytes: uint = 0
    for blk in blocks:
      bytes += blk.data.len.uint
    if err =? (await reservations.partialRelease(availability.id, bytes)).errorOption:
      # TODO: need to return SaleErrored in the closure somehow
      error "Error releasing bytes and resizing availability", error = err.msg

  if err =? (await onStore(request,
                           data.slotIndex,
                           some availability,
                           onBatch)).errorOption:
    return some State(SaleErrored(error: err))

  if err =? (await reservations.markUnused(availability.id)).errorOption:
    return some State(SaleErrored(error: err))

  # TODO: data.availability is not used in any of the callbacks, remove it from
  # the callbacks? If so, this block is not needed:
  if a =? await reservations.get(availability.id):
    data.availability = some a

  return some State(SaleProving())
