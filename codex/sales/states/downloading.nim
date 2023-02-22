import std/sequtils
import ../../market
import ../salesagent
import ../statemachine
import ../salesagent
import ./cancelled
import ./failed
import ./filled
import ./proving
import ./errored

type
  SaleDownloading* = ref object of SaleState
    failedSubscription: ?market.Subscription
    hasCancelled: ?Future[void]
  SaleDownloadingError* = object of SaleError

method `$`*(state: SaleDownloading): string = "SaleDownloading"

method onCancelled*(state: SaleDownloading, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleDownloading, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(state: SaleDownloading, requestId: RequestId,
                     slotIndex: UInt256): ?State =
  return some State(SaleFilled())

method run*(state: SaleDownloading, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let context = SalesAgent(machine).context

  try:
    without onStore =? context.onStore:
      raiseAssert "onStore callback not set"

    without request =? data.request:
      raiseAssert "no sale request"

    await onStore(request, data.slotIndex, data.availability)
    return some State(SaleProving())

  except CancelledError:
    raise

  except CatchableError as e:
    let error = newException(SaleDownloadingError,
                             "unknown sale downloading error",
                             e)
    return some State(SaleErrored(error: error))
