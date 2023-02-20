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

method run*(state: SaleDownloading, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)

  try:
    without onStore =? agent.sales.onStore:
      raiseAssert "onStore callback not set"

    if availability =? agent.availability:
      agent.sales.remove(availability)

    await onStore(agent.request, agent.slotIndex, agent.availability)
    agent.downloaded.setValue(true)

  except CancelledError:
    raise

