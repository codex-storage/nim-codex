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
import ./ignored
import ./proving
import ./errored

type
  SaleDownloading* = ref object of ErrorHandlingState

logScope:
    topics = "sales downloading"

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
      request.ask.collateral,
      used = false):
    info "no availability found for request, ignoring",
      slotSize = request.ask.slotSize,
      duration = request.ask.duration,
      pricePerSlot = request.ask.pricePerSlot,
      used = false
    return some State(SaleIgnored())

  # mark availability as used so that it is not matched to other requests
  if markUsedErr =? (await reservations.markUsed(availability.id)).errorOption:
    return some State(SaleErrored(error: markUsedErr))

  proc onBatch(blocks: seq[bt.Block]) {.async.} =
    # release batches of blocks as they are written to disk and
    # update availability size
    var bytes: uint = 0
    for blk in blocks:
      bytes += blk.data.len.uint

    trace "Releasing batch of bytes written to disk", bytes
    let r = await reservations.release(availability.id, bytes)
    # `tryGet` will raise the exception that occurred during release, if there
    # was one. The exception will be caught in the closure and sent to the
    # SaleErrored state.
    r.tryGet()

  template markUnused(id: AvailabilityId) =
    if markUnusedErr =? (await reservations.markUnused(id)).errorOption:
      return some State(SaleErrored(error: markUnusedErr))

  trace "Starting download"
  if err =? (await onStore(request,
                           data.slotIndex,
                           onBatch)).errorOption:

    markUnused(availability.id)
    return some State(SaleErrored(error: err))

  trace "Download complete"

  markUnused(availability.id)
  return some State(SaleProving())
