import pkg/questionable
import pkg/questionable/results

import ../../blocktype as bt
import ../../logutils
import ../../market
import ../../utils/exceptions
import ../salesagent
import ../statemachine
import ./cancelled
import ./failed
import ./filled
import ./initialproving
import ./errored

type SaleDownloading* = ref object of SaleState

logScope:
  topics = "marketplace sales downloading"

method `$`*(state: SaleDownloading): string =
  "SaleDownloading"

method onCancelled*(state: SaleDownloading, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleDownloading, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(
    state: SaleDownloading, requestId: RequestId, slotIndex: uint64
): ?State =
  return some State(SaleFilled())

method run*(
    state: SaleDownloading, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let reservations = context.reservations

  without onStore =? context.onStore:
    raiseAssert "onStore callback not set"

  without request =? data.request:
    raiseAssert "no sale request"

  without reservation =? data.reservation:
    raiseAssert("no reservation")

  logScope:
    requestId = request.id
    slotIndex = data.slotIndex
    reservationId = reservation.id
    availabilityId = reservation.availabilityId

  proc onBlocks(
      blocks: seq[bt.Block]
  ): Future[?!void] {.async: (raises: [CancelledError]).} =
    # release batches of blocks as they are written to disk and
    # update availability size
    var bytes: uint = 0
    for blk in blocks:
      if not blk.cid.isEmpty:
        bytes += blk.data.len.uint

    trace "Releasing batch of bytes written to disk", bytes
    return await reservations.release(reservation.id, reservation.availabilityId, bytes)

  try:
    let slotId = slotId(request.id, data.slotIndex)
    let isRepairing = (await context.market.slotState(slotId)) == SlotState.Repair

    trace "Starting download"
    if err =? (await onStore(request, data.slotIndex, onBlocks, isRepairing)).errorOption:
      return some State(SaleErrored(error: err, reprocessSlot: false))

    trace "Download complete"
    return some State(SaleInitialProving())
  except CancelledError as e:
    trace "SaleDownloading.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleDownloading.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
