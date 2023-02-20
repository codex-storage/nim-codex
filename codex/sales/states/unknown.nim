import ../statemachine
import ./filled
import ./finished
import ./failed
import ./errored
import ./cancelled

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
  let market = agent.sales.market

#   try:
#     let slotId = slotId(agent.request.id, agent.slotIndex)

#     without slotState =? await market.slotState(slotId):
#       let error = newException(SaleUnknownError, "cannot retrieve slot state")
#       agent.setError error

#     if slotState == SlotState.Free:
#       let error = newException(UnexpectedSlotError,
#         "slot state on chain should not be 'free'")
#       agent.setError error

#     agent.slotState.setValue(slotState)

#   except CancelledError:
#     raise

#   except CatchableError as e:
#     let error = newException(SaleUnknownError,
#                              "error in unknown state",
#                              e)
#     agent.setError error
