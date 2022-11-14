import ../statemachine
import ./filling
import ./cancelled
import ./failed
import ./filled
import ./errored

type
  SaleProving* = ref object of SaleState
  SaleProvingError* = object of CatchableError

method `$`*(state: SaleProving): string = "SaleProving"

method onCancelled*(state: SaleProving, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleCancelled())

method onFailed*(state: SaleProving, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleFailed())

method onSlotFilled*(state: SaleProving, requestId: RequestId,
                     slotIndex: UInt256) {.async.} =
  await state.switchAsync(SaleFilled())

method enterAsync(state: SaleProving) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  try:
    without request =? agent.request:
      raiseAssert "no sale request"

    without slotIndex =? agent.slotIndex:
      raiseAssert "no slot selected"

    without onProve =? agent.sales.onProve:
      raiseAssert "onProve callback not set"

    let proof = await onProve(request, slotIndex)
    await state.switchAsync(SaleFilling(proof: proof))

  except CancelledError:
    discard

  except CatchableError as e:
    let error = newException(SaleProvingError, "unknown sale proving error", e)
    await state.switchAsync(SaleErrored(error: error))
