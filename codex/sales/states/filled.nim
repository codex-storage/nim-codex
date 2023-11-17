import pkg/questionable
import pkg/chronicles
import ../../conf
import ../statemachine
import ../salesagent
import ./errorhandling
import ./errored
import ./cancelled
import ./failed
import ./proving
import ./provingsimulated

logScope:
  topics = "marketplace sales filled"

type
  SaleFilled* = ref object of ErrorHandlingState
  HostMismatchError* = object of CatchableError

method onCancelled*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleFailed())

method `$`*(state: SaleFilled): string = "SaleFilled"

method run*(state: SaleFilled, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context

  let market = context.market
  let host = await market.getHost(data.requestId, data.slotIndex)
  let me = await market.getSigner()

  if host == me.some:
    info "Slot succesfully filled", requestId = $data.requestId, slotIndex = $data.slotIndex

    if request =? data.request:
      if onFilled =? agent.onFilled:
        onFilled(request, data.slotIndex)

    when codex_enable_proof_failures:
      if context.simulateProofFailures > 0:
        info "Proving with failure rate", rate = context.simulateProofFailures
        return some State(SaleProvingSimulated(failEveryNProofs: context.simulateProofFailures))

    return some State(SaleProving())

  else:
    let error = newException(HostMismatchError, "Slot filled by other host")
    return some State(SaleErrored(error: error))
