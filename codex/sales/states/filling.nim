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

method onCancelled*(state: SaleFilling, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilling, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(state: SaleFilling, requestId: RequestId,
                     slotIndex: UInt256): ?State =
  return some State(SaleFilled())

method run(state: SaleFilling, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)

  try:
    let market = agent.sales.market

    await market.fillSlot(agent.request.id, agent.slotIndex, state.proof)

  except CancelledError:
    raise

  except CatchableError as e:
    let error = newException(SaleFillingError, "unknown sale filling error", e)
    return some State(SaleErrored(error: error))
