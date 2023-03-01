import pkg/upraises
import pkg/chronicles
import ../statemachine
import ../salesagent

type SaleErrored* = ref object of SaleState
  error*: ref CatchableError

method `$`*(state: SaleErrored): string = "SaleErrored"

method onError*(state: SaleState, err: ref CatchableError): ?State {.upraises:[].} =
  error "error during SaleErrored run", error = err.msg

method run*(state: SaleErrored, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context

  if onClear =? context.onClear and
      request =? data.request and
      slotIndex =? data.slotIndex:
    onClear(data.availability, request, slotIndex)

  # TODO: when availability persistence is added, change this to not optional
  # NOTE: with this in place, restoring state for a restarted node will
  # never free up availability once finished. Persisting availability
  # on disk is required for this.
  if onSaleErrored =? context.onSaleErrored and
     availability =? data.availability:
    onSaleErrored(availability)

    await agent.unsubscribe()

  error "Sale error", error=state.error.msg
