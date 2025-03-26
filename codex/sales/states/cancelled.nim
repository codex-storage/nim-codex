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
    var returnedCollateral = UInt256.none

    if await slotIsFilledByMe(market, data.requestId, data.slotIndex):
      debug "Collecting collateral and partial payout",
        requestId = data.requestId, slotIndex = data.slotIndex

      let slot = Slot(request: request, slotIndex: data.slotIndex)
      let currentCollateral = await market.currentCollateral(slot.id)

      try:
        await market.freeSlot(slot.id)
      except SlotStateMismatchError as e:
        warn "Failed to free slot because slot is already free", error = e.msg

      returnedCollateral = currentCollateral.some

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
