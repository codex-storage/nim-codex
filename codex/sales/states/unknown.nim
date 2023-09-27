import pkg/chronicles
import ../statemachine
import ../salesagent
import ./filled
import ./finished
import ./failed
import ./errored
import ./cancelled
import ./payout

logScope:
    topics = "marketplace sales unknown"

type
  SaleUnknown* = ref object of SaleState
  SaleUnknownError* = object of CatchableError
  UnexpectedSlotError* = object of SaleUnknownError

method `$`*(state: SaleUnknown): string = "SaleUnknown"

method onCancelled*(state: SaleUnknown, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleUnknown, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(state: SaleUnknown, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let market = agent.context.market

  await agent.retrieveRequest()
  await agent.subscribe()

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  let slotId = slotId(data.requestId, slotIndex)

  without slotState =? await market.slotState(slotId):
    let error = newException(SaleUnknownError, "cannot retrieve slot state")
    return some State(SaleErrored(error: error))

  case slotState
  of SlotState.Free:
    let error = newException(UnexpectedSlotError,
      "slot state on chain should not be 'free'")
    return some State(SaleErrored(error: error))
  of SlotState.Filled:
    return some State(SaleFilled())
  of SlotState.Finished:
    return some State(SalePayout())
  of SlotState.Paid:
    return some State(SaleFinished())
  of SlotState.Failed:
    return some State(SaleFailed())
