import pkg/chronos

import ../../logutils
import ../../utils/exceptions
import ../statemachine
import ../salesagent
import ./errored

logScope:
  topics = "marketplace sales ignored"

# Ignored slots could mean there was no availability or that the slot could
# not be reserved.

type SaleIgnored* = ref object of SaleState
  reprocessSlot*: bool # readd slot to queue with `seen` flag

method `$`*(state: SaleIgnored): string =
  "SaleIgnored"

method run*(
    state: SaleIgnored, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)

  try:
    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(reprocessSlot = state.reprocessSlot)
  except CancelledError as e:
    trace "SaleIgnored.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleIgnored.run in onCleanUp", error = e.msgDetail
    return some State(SaleErrored(error: e))
