import pkg/chronos
import ../statemachine
import ../salesagent
import ./errorhandling
import ./cancelled
import ./failed

type
  SaleFinished* = ref object of ErrorHandlingState

method `$`*(state: SaleFinished): string = "SaleFinished"

method onCancelled*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(state: SaleFinished, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context

  if request =? data.request and
      slotIndex =? data.slotIndex:
    context.proving.add(Slot(request: request, slotIndex: slotIndex))

    if onSale =? context.onSale:
      onSale(request, slotIndex)

  # TODO: Keep track of contract completion using local clock. When contract
  # has finished, we need to add back availability to the sales module.
  # This will change when the state machine is updated to include the entire
  # sales process, as well as when availability is persisted, so leaving it
  # as a TODO for now.

  await agent.unsubscribe()
