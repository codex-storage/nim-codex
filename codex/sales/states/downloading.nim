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
  SaleDownloading* = ref object of State
    failedSubscription: ?market.Subscription
    hasCancelled: ?Future[void]
  SaleDownloadingError* = object of SaleError

method `$`*(state: SaleDownloading): string = "SaleDownloading"

method run*(state: SaleDownloading, machine: Machine): Future[?State] {.async.} =
  # echo "running ", state
  let agent = SalesAgent(machine)

  try:
    without onStore =? agent.sales.onStore:
      raiseAssert "onStore callback not set"

    without request =? agent.request:
      let error = newException(SaleDownloadingError, "missing request")
      agent.setError error
      return

    if availability =? agent.availability:
      agent.sales.remove(availability)

    await onStore(request, agent.slotIndex, agent.availability)
    agent.downloaded.setValue(true)

  except CancelledError:
    raise

