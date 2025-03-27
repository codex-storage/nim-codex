import ../../logutils
import ../../utils/exceptions
import ../../utils/exceptions
import ../salesagent
import ../statemachine
import ./errored

logScope:
  topics = "marketplace sales failed"

type
  SaleFailed* = ref object of SaleState
  SaleFailedError* = object of SaleError

method `$`*(state: SaleFailed): string =
  "SaleFailed"

method run*(
    state: SaleFailed, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let data = SalesAgent(machine).data
  let market = SalesAgent(machine).context.market

  without request =? data.request:
    raiseAssert "no sale request"

  try:
    let slot = Slot(request: request, slotIndex: data.slotIndex)
    debug "Removing slot from mySlots",
      requestId = data.requestId, slotIndex = data.slotIndex

    await market.freeSlot(slot.id)

    let error = newException(SaleFailedError, "Sale failed")
    return some State(SaleErrored(error: error))
  except CancelledError as e:
    trace "SaleFailed.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleFailed.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
