import pkg/chronos

import ../../logutils
import ../statemachine
import ../salesagent
import ./errorhandling

logScope:
  topics = "marketplace sales ignored"

type
  SaleIgnored* = ref object of ErrorHandlingState

method `$`*(state: SaleIgnored): string = "SaleIgnored"

method run*(state: SaleIgnored, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)

  if onCleanUp =? agent.onCleanUp:
    # Ignored slots mean there was no availability. In order to prevent small
    # availabilities from draining the queue, mark this slot as seen and re-add
    # back into the queue.
    await onCleanUp(reprocessSlot = true)
