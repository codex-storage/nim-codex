import ../statemachine
import ../salesagent
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
  let data = SalesAgent(machine).data
  let context = SalesAgent(machine).context

  try:
    without request =? data.request:
      raiseAssert "no sale request"

    without onProve =? context.onProve:
      raiseAssert "onProve callback not set"

    let proof = await onProve(request, data.slotIndex)
    return some State(SaleFilling(proof: proof))

  except CancelledError:
    raise

  except CatchableError as e:
    let error = newException(SaleProvingError, "unknown sale proving error", e)
    return some State(SaleErrored(error: error))
