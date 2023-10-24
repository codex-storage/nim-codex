import pkg/chronicles
import ../salesagent
import ../statemachine
import ./errorhandling
import ./errored

logScope:
  topics = "marketplace sales cancelled"

type
  SaleCancelled* = ref object of ErrorHandlingState

method `$`*(state: SaleCancelled): string = "SaleCancelled"

method run*(state: SaleCancelled, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let market = agent.context.market

  without request =? data.request:
    raiseAssert "no sale request"

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  let slot = Slot(request: request, slotIndex: slotIndex)
  debug "Collecting collateral and partial payout",  requestId = $data.requestId, slotIndex
  await market.freeSlot(slot.id)

  if onClear =? agent.context.onClear and
      request =? data.request and
      slotIndex =? data.slotIndex:
    onClear(request, slotIndex)

  if onCleanUp =? agent.onCleanUp:
    await onCleanUp()

  warn "Sale cancelled due to timeout",  requestId = $data.requestId, slotIndex
