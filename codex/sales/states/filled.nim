import pkg/questionable
import ./errored
import ./finished
import ./cancelled
import ./failed
import ../statemachine

type
  SaleFilled* = ref object of SaleState
  SaleFilledError* = object of CatchableError

method onCancelled*(state: SaleFilled, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleCancelled())

method onFailed*(state: SaleFilled, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleFailed())

method `$`*(state: SaleFilled): string = "SaleFilled"

method enterAsync(state: SaleFilled) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  try:
    let market = agent.sales.market

    without slotIndex =? agent.slotIndex:
      raiseAssert "no slot selected"

    let host = await market.getHost(agent.requestId, slotIndex)
    let me = await market.getSigner()
    if host == me.some:
      await state.switchAsync(SaleFinished())
    else:
      let error = newException(SaleFilledError, "Slot filled by other host")
      await state.switchAsync(SaleErrored(error: error))

  except CancelledError:
    discard

  except CatchableError as e:
    let error = newException(SaleFilledError, "sale filled error", e)
    await state.switchAsync(SaleErrored(error: error))
