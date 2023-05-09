import pkg/chronicles
import ../statemachine
import ../salesagent
import ./errorhandling

type
  SaleRestart* = ref object of ErrorHandlingState

logScope:
  topics = "sales restart"

method `$`*(state: SaleRestart): string = "SaleRestart"

method run*(state: SaleRestart, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  if onStartOver =? context.onStartOver:
    notice "Slot filled by other host, starting over",
      requestId = data.requestId, slotIndex
    await onStartOver(slotIndex)
