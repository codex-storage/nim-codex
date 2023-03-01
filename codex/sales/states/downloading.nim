import ../../market
import ../salesagent
import ../statemachine
import ./errorhandling
import ./cancelled
import ./failed
import ./filled
import ./proving
import ./errored

type
  SaleDownloading* = ref object of ErrorHandlingState
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
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context

  try:
    await agent.retrieveRequest()
    await agent.subscribe()

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
