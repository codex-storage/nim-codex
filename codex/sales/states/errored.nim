import chronicles
import ../statemachine

type SaleErrored* = ref object of SaleState
  error*: ref CatchableError

method `$`*(state: SaleErrored): string = "SaleErrored"

method run*(state: SaleErrored, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data

  if onClear =? data.sales.onClear and
      request =? data.request and
      slotIndex =? data.slotIndex:
    onClear(data.availability, request, slotIndex)

  # TODO: when availability persistence is added, change this to not optional
  # NOTE: with this in place, restoring state for a restarted node will
  # never free up availability once finished. Persisting availability
  # on disk is required for this.
  if availability =? data.availability:
    data.sales.add(availability)

  error "Sale error", error=state.error.msg
