import pkg/chronos

import ../../logutils
import ../../utils/exceptions
import ../statemachine
import ../salesagent
import ./errored

logScope:
  topics = "marketplace sales ignored"

# Ignored slots could mean there was no availability or that the slot could
# not be reserved.

type SaleIgnored* = ref object of SaleState
  reprocessSlot*: bool # readd slot to queue with `seen` flag
  returnsCollateral*: bool # returns collateral when a reservation was created

method `$`*(state: SaleIgnored): string =
  "SaleIgnored"

method run*(
    state: SaleIgnored, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let market = agent.context.market

  without request =? data.request:
    raiseAssert "no sale request"

  var returnedCollateral = UInt256.none

  try:
    if state.returnsCollateral:
      # The returnedCollateral is needed because a reservation could
      # be created and the collateral assigned to that reservation.
      # The returnedCollateral will be used in the cleanup function
      # and be passed to the deleteReservation function.
      let slot = Slot(request: request, slotIndex: data.slotIndex)
      returnedCollateral = request.ask.collateralPerSlot.some

    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(
        reprocessSlot = state.reprocessSlot, returnedCollateral = returnedCollateral
      )
  except CancelledError as e:
    trace "SaleIgnored.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleIgnored.run in onCleanUp", error = e.msgDetail
    return some State(SaleErrored(error: e))
