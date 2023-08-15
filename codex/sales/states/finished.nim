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

  without request =? data.request:
    raiseAssert "no sale request"

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  info "Slot finished and paid out", requestId = $data.requestId, slotIndex

  if onCleanUp =? context.onCleanUp:
    await onCleanUp()
