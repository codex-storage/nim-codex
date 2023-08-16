import pkg/chronos
import pkg/chronicles
import ../statemachine
import ../salesagent
import ./errorhandling
import ./cancelled
import ./failed

logScope:
    topics = "marketplace sales finished"

type
  SaleFinished* = ref object of ErrorHandlingState

method `$`*(state: SaleFinished): string = "SaleFinished"

method onCancelled*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(state: SaleFinished, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context

  debug "Request succesfully filled", requestId = $data.requestId

  if request =? data.request and
      slotIndex =? data.slotIndex:
    let slot = Slot(request: request, slotIndex: slotIndex)
    debug "Adding slot to proving list", slotId = $slot.id
    context.proving.add(slot)

    if onSale =? context.onSale:
      onSale(request, slotIndex)

  if onCleanUp =? context.onCleanUp:
    await onCleanUp()
