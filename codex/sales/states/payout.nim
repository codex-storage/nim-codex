import ../../logutils
import ../../market
import ../../utils/exceptions
import ../statemachine
import ../salesagent
import ./errorhandling
import ./cancelled
import ./failed
import ./finished
import ./errored

logScope:
  topics = "marketplace sales payout"

type SalePayout* = ref object of ErrorHandlingState

method `$`*(state: SalePayout): string =
  "SalePayout"

method onCancelled*(state: SalePayout, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SalePayout, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(
    state: SalePayout, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let data = SalesAgent(machine).data
  let market = SalesAgent(machine).context.market

  without request =? data.request:
    raiseAssert "no sale request"

  try:
    let slot = Slot(request: request, slotIndex: data.slotIndex)
    debug "Collecting finished slot's reward",
      requestId = data.requestId, slotIndex = data.slotIndex
    let currentCollateral = await market.currentCollateral(slot.id)
    await market.freeSlot(slot.id)

    return some State(SaleFinished(returnedCollateral: some currentCollateral))
  except CancelledError as e:
    trace "SalePayout.run onCleanUp was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SalePayout.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
