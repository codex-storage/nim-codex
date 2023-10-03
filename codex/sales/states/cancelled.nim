import pkg/chronicles
import ../salesagent
import ../statemachine
import ./errorhandling
import ./errored

logScope:
  topics = "marketplace sales cancelled"

type
  SaleCancelled* = ref object of ErrorHandlingState
  SaleCancelledError* = object of CatchableError
  SaleTimeoutError* = object of SaleCancelledError

method `$`*(state: SaleCancelled): string = "SaleCancelled"

method run*(state: SaleCancelled, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let market = SalesAgent(machine).context.market

  without request =? data.request:
    raiseAssert "no sale request"

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  let slot = Slot(request: request, slotIndex: slotIndex)
  debug "Collecting collateral and partial payout",  requestId = $data.requestId, slotIndex
  await market.freeSlot(slot.id)

  let error = newException(SaleTimeoutError, "Sale cancelled due to timeout")
  return some State(SaleErrored(error: error))
