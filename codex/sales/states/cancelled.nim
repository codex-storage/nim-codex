import ../../logutils
import ../../utils/exceptions
import ../salesagent
import ../statemachine
import ./errored

logScope:
  topics = "marketplace sales cancelled"

type SaleCancelled* = ref object of SaleState

method `$`*(state: SaleCancelled): string =
  "SaleCancelled"

method run*(
    state: SaleCancelled, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let market = agent.context.market

  without request =? data.request:
    raiseAssert "no sale request"

  try:
    let slot = Slot(request: request, slotIndex: data.slotIndex)
    debug "Collecting collateral and partial payout",
      requestId = data.requestId, slotIndex = data.slotIndex
    let currentCollateral = await market.currentCollateral(slot.id)
    await market.freeSlot(slot.id)

    if onClear =? agent.context.onClear and request =? data.request:
      onClear(request, data.slotIndex)

    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(
        returnBytes = true,
        reprocessSlot = false,
        returnedCollateral = some currentCollateral,
      )

    warn "Sale cancelled due to timeout",
      requestId = data.requestId, slotIndex = data.slotIndex
  except CancelledError as e:
    trace "SaleCancelled.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleCancelled.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
