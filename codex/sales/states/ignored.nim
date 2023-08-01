import pkg/chronicles
import pkg/chronos
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
  let context = agent.context

  if onCleanUp =? context.onCleanUp:
    await onCleanUp()
