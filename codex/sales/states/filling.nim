import pkg/upraises
import ../../market
import ../statemachine
import ./filled
import ./errored
import ./cancelled
import ./failed

type
  SaleFilling* = ref object of SaleState
    proof*: seq[byte]
  SaleFillingError* = object of CatchableError

method `$`*(state: SaleFilling): string = "SaleFilling"

method onCancelled*(state: SaleFilling, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleCancelled())

method onFailed*(state: SaleFilling, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleFailed())

method onSlotFilled*(state: SaleFilling, requestId: RequestId,
                     slotIndex: UInt256) {.async.} =
  await state.switchAsync(SaleFilled())

method enterAsync(state: SaleFilling) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  try:
    let market = agent.sales.market

    without slotIndex =? agent.slotIndex:
      raiseAssert "no slot selected"

    await market.fillSlot(agent.requestId, slotIndex, state.proof)

  except CancelledError:
    discard

  except CatchableError as e:
    let error = newException(SaleFillingError, "unknown sale filling error", e)
    await state.switchAsync(SaleErrored(error: error))
