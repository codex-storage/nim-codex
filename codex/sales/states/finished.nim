import pkg/chronos

import ../../logutils
import ../../utils/exceptions
import ../statemachine
import ../salesagent
import ./cancelled
import ./failed
import ./errored

logScope:
  topics = "marketplace sales finished"

type SaleFinished* = ref object of SaleState
  returnedCollateral*: ?UInt256

method `$`*(state: SaleFinished): string =
  "SaleFinished"

method onCancelled*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(
    state: SaleFinished, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data

  without request =? data.request:
    raiseAssert "no sale request"

  info "Slot finished and paid out",
    requestId = data.requestId, slotIndex = data.slotIndex

  try:
    if onClear =? agent.context.onClear:
      onClear(request, data.slotIndex)

    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(returnedCollateral = state.returnedCollateral)
  except CancelledError as e:
    trace "SaleFilled.run onCleanUp was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleFilled.run in onCleanUp callback", error = e.msgDetail
    return some State(SaleErrored(error: e))
