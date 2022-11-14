import std/sequtils
import ./cancelled
import ./failed
import ./filled
import ./proving
import ./errored
import ../salesagent
import ../statemachine
import ../../market

type
  SaleDownloading* = ref object of SaleState
    failedSubscription: ?market.Subscription
    hasCancelled: ?Future[void]
  SaleDownloadingError* = object of SaleError

method `$`*(state: SaleDownloading): string = "SaleDownloading"

method onCancelled*(state: SaleDownloading, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleCancelled())

method onFailed*(state: SaleDownloading, request: StorageRequest) {.async.} =
  await state.switchAsync(SaleFailed())

method onSlotFilled*(state: SaleDownloading, requestId: RequestId,
                     slotIndex: UInt256) {.async.} =
  await state.switchAsync(SaleFilled())

method enterAsync(state: SaleDownloading) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  try:
    without onStore =? agent.sales.onStore:
      raiseAssert "onStore callback not set"

    without slotIndex =? agent.slotIndex:
      raiseAssert "no slot selected"

    without request =? agent.request:
      raiseAssert "no sale request"

    if availability =? agent.availability:
      agent.sales.remove(availability)

    await onStore(request, slotIndex, agent.availability)
    await state.switchAsync(SaleProving())

  except CancelledError:
    discard

  except CatchableError as e:
    let error = newException(SaleDownloadingError,
                             "unknown sale downloading error",
                             e)
    await state.switchAsync(SaleErrored(error: error))
