import pkg/stint
import ../../logutils
import ../../market
import ../../utils/exceptions
import ../statemachine
import ../salesagent
import ./filled
import ./cancelled
import ./failed
import ./ignored
import ./errored

logScope:
  topics = "marketplace sales filling"

type SaleFilling* = ref object of SaleState
  proof*: Groth16Proof

method `$`*(state: SaleFilling): string =
  "SaleFilling"

method onCancelled*(state: SaleFilling, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilling, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(
    state: SaleFilling, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let data = SalesAgent(machine).data
  let market = SalesAgent(machine).context.market

  without (request =? data.request):
    raiseAssert "Request not set"

  logScope:
    requestId = data.requestId
    slotIndex = data.slotIndex

  let collateral = request.ask.collateralPerSlot()
  try:
    debug "Filling slot"
    try:
      await market.fillSlot(data.requestId, data.slotIndex, state.proof, collateral)
    except SlotStateMismatchError as e:
      debug "Slot is already filled, ignoring slot"
      return some State(SaleIgnored(reprocessSlot: false))
    except MarketError as e:
      return some State(SaleErrored(error: e))

    return some State(SaleFilled())
  except CancelledError as e:
    trace "SaleFilling.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleFilling.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
