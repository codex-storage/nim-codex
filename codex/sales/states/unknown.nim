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

method onCancelled*(state: SaleUnknown, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleCancelled())

method onFailed*(state: SaleUnknown, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleFailed())

method enterAsync(state: SaleUnknown) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  let market = agent.sales.market

  try:
    let slotId = slotId(agent.requestId, agent.slotIndex)

    without slotState =? await market.slotState(slotId):
      let error = newException(SaleUnknownError, "cannot retrieve slot state")
      await state.switchAsync(SaleErrored(error: error))

    case slotState
    of SlotState.Free:
      let error = newException(UnexpectedSlotError,
        "slot state on chain should not be 'free'")
      await state.switchAsync(SaleErrored(error: error))
    of SlotState.Filled:
      await state.switchAsync(SaleFilled())
    of SlotState.Finished, SlotState.Paid:
      await state.switchAsync(SaleFinished())
    of SlotState.Failed:
      await state.switchAsync(SaleFailed())

  except CancelledError:
    discard

  except CatchableError as e:
    let error = newException(SaleUnknownError,
                             "error in unknown state",
                             e)
    await state.switchAsync(SaleErrored(error: error))
