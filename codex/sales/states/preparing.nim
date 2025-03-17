import pkg/questionable
import pkg/questionable/results
import pkg/metrics

import ../../logutils
import ../../market
import ../../utils/exceptions
import ../salesagent
import ../statemachine
import ./cancelled
import ./failed
import ./filled
import ./ignored
import ./slotreserving
import ./errored

declareCounter(
  codex_reservations_availability_mismatch, "codex reservations availability_mismatch"
)

type SalePreparing* = ref object of SaleState

logScope:
  topics = "marketplace sales preparing"

method `$`*(state: SalePreparing): string =
  "SalePreparing"

method onCancelled*(state: SalePreparing, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SalePreparing, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(
    state: SalePreparing, requestId: RequestId, slotIndex: uint64
): ?State =
  return some State(SaleFilled())

method run*(
    state: SalePreparing, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let market = context.market
  let reservations = context.reservations

  try:
    await agent.retrieveRequest()
    await agent.subscribe()

    without request =? data.request:
      raiseAssert "no sale request"

    let slotId = slotId(data.requestId, data.slotIndex)
    let state = await market.slotState(slotId)
    if state != SlotState.Free and state != SlotState.Repair:
      return some State(SaleIgnored(reprocessSlot: false))

    # TODO: Once implemented, check to ensure the host is allowed to fill the slot,
    # due to the [sliding window mechanism](https://github.com/codex-storage/codex-research/blob/master/design/marketplace.md#dispersal)

    logScope:
      slotIndex = data.slotIndex
      slotSize = request.ask.slotSize
      duration = request.ask.duration
      pricePerBytePerSecond = request.ask.pricePerBytePerSecond
      collateralPerByte = request.ask.collateralPerByte

    let requestEnd = await market.getRequestEnd(data.requestId)

    without availability =?
      await reservations.findAvailability(
        request.ask.slotSize, request.ask.duration, request.ask.pricePerBytePerSecond,
        request.ask.collateralPerByte, requestEnd,
      ):
      debug "No availability found for request, ignoring"

      return some State(SaleIgnored(reprocessSlot: true))

    info "Availability found for request, creating reservation"

    without reservation =?
      await reservations.createReservation(
        availability.id, request.ask.slotSize, request.id, data.slotIndex,
        request.ask.collateralPerByte, requestEnd,
      ), error:
      trace "Creation of reservation failed"
      # Race condition:
      # reservations.findAvailability (line 64) is no guarantee. You can never know for certain that the reservation can be created until after you have it.
      # Should createReservation fail because there's no space, we proceed to SaleIgnored.
      if error of BytesOutOfBoundsError:
        # Lets monitor how often this happen and if it is often we can make it more inteligent to handle it
        codex_reservations_availability_mismatch.inc()
        return some State(SaleIgnored(reprocessSlot: true))

      return some State(SaleErrored(error: error))

    trace "Reservation created successfully"

    data.reservation = some reservation
    return some State(SaleSlotReserving())
  except CancelledError as e:
    trace "SalePreparing.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SalePreparing.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
