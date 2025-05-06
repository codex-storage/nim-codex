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

proc slotIsFilledByMe(
    market: Market, requestId: RequestId, slotIndex: uint64
): Future[bool] {.async: (raises: [CancelledError, MarketError]).} =
  let host = await market.getHost(requestId, slotIndex)
  let me = await market.getSigner()

  return host == me.some

method run*(
    state: SaleCancelled, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let market = agent.context.market

  without request =? data.request:
    raiseAssert "no sale request"

  try:
    debug "Collecting collateral and partial payout",
      requestId = data.requestId, slotIndex = data.slotIndex

    # The returnedCollateral is needed even if the slot is not filled by the host
    # because a reservation could be created and the collateral assigned
    # to that reservation. So if the slot is not filled by that host,
    # the reservation will be deleted during cleanup and the collateral
    # must be returned to the host.
    let slot = Slot(request: request, slotIndex: data.slotIndex)
    let currentCollateral = await market.currentCollateral(slot.id)
    let returnedCollateral = currentCollateral.some

    if await slotIsFilledByMe(market, data.requestId, data.slotIndex):
      try:
        await market.freeSlot(slot.id)
      except SlotStateMismatchError as e:
        warn "Failed to free slot because slot is already free", error = e.msg

    if onClear =? agent.context.onClear and request =? data.request:
      onClear(request, data.slotIndex)

    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(reprocessSlot = false, returnedCollateral = returnedCollateral)

    warn "Sale cancelled due to timeout",
      requestId = data.requestId, slotIndex = data.slotIndex
  except CancelledError as e:
    trace "SaleCancelled.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleCancelled.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
