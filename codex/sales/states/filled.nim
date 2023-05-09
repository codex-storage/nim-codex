import pkg/chronicles
import pkg/questionable
import ../statemachine
import ../salesagent
import ./errorhandling
import ./finished
import ./cancelled
import ./failed
import ./restart

type
  SaleFilled* = ref object of ErrorHandlingState
  HostMismatchError* = object of CatchableError

logScope:
  topics = "sales filled"

method onCancelled*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleFailed())

method `$`*(state: SaleFilled): string = "SaleFilled"

method run*(state: SaleFilled, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let context = agent.context
  let data = agent.data
  let market = context.market

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  let host = await market.getHost(data.requestId, slotIndex)
  let me = await market.getSigner()
  if host == me.some:
    return some State(SaleFinished())
  else:
    return some State(SaleRestart())
