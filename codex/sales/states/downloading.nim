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
import ./initialproving
import ./errored

type
  SaleDownloading* = ref object of ErrorHandlingState

logScope:
  topics = "marketplace sales downloading"

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

  without onStore =? context.onStore:
    raiseAssert "onStore callback not set"

  without request =? data.request:
    raiseAssert "no sale request"

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  without reservation =? data.reservation:
    raiseAssert("no reservation")

  logScope:
    requestId = request.id
    slotIndex
    reservationId = reservation.id
    availabilityId = reservation.availabilityId

  proc onBatch(blocks: seq[bt.Block]) {.async.} =
    # release batches of blocks as they are written to disk and
    # update availability size
    var bytes: uint = 0
    for blk in blocks:
      bytes += blk.data.len.uint

    trace "Releasing batch of bytes written to disk", bytes
    let r = await reservations.release(reservation.id,
                                       reservation.availabilityId,
                                       bytes)
    # `tryGet` will raise the exception that occurred during release, if there
    # was one. The exception will be caught in the closure and sent to the
    # SaleErrored state.
    r.tryGet()

  trace "Starting download"
  if err =? (await onStore(request,
                           slotIndex,
                           onBatch)).errorOption:
    return some State(SaleErrored(error: err))

  trace "Download complete"
  return some State(SaleInitialProving())
