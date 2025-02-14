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

  try:
    let slotState = await market.slotState(slotId(data.requestId, data.slotIndex))
    let requestedCollateral = request.ask.collateralPerSlot
    var collateral: UInt256

    if slotState == SlotState.Repair:
      # When repairing the node gets "discount" on the collateral that it needs to
      let repairRewardPercentage = (await market.repairRewardPercentage).u256
      collateral =
        requestedCollateral -
        ((requestedCollateral * repairRewardPercentage)).div(100.u256)
    else:
      collateral = requestedCollateral

    debug "Filling slot"
    try:
      await market.fillSlot(data.requestId, data.slotIndex, state.proof, collateral)
    except MarketError as e:
      if e.msg.contains "Slot is not free":
        debug "Slot is already filled, ignoring slot"
        return some State(SaleIgnored(reprocessSlot: false, returnBytes: true))
      else:
        return some State(SaleErrored(error: e))
    # other CatchableErrors are handled "automatically" by the SaleState

    return some State(SaleFilled())
  except CancelledError as e:
    trace "SaleFilling.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleFilling.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
