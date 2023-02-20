import ../statemachine
import ./filling
import ./cancelled
import ./failed
import ./filled
import ./errored

type
  SaleProving* = ref object of SaleState
  SaleProvingError* = object of CatchableError

method `$`*(state: SaleProving): string = "SaleProving"

method onCancelled*(state: SaleProving, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleProving, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(state: SaleProving, requestId: RequestId,
                     slotIndex: UInt256): ?State =
  return some State(SaleFilled())

method run*(state: SaleProving, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)

  try:
    without onProve =? agent.sales.onProve:
      raiseAssert "onProve callback not set"

    let proof = await onProve(agent.request, agent.slotIndex)
    agent.proof.setValue(proof)

  except CancelledError:
    raise

  except CatchableError as e:
    let error = newException(SaleProvingError, "unknown sale proving error", e)
    machine.setError error
