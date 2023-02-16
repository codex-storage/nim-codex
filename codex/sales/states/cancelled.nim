import ../statemachine
import ./errored

type
  SaleCancelled* = ref object of SaleState
  SaleCancelledError* = object of CatchableError
  SaleTimeoutError* = object of SaleCancelledError

method `$`*(state: SaleCancelled): string = "SaleCancelled"

method run*(state: SaleCancelled, machine: Machine): Future[?State] {.async.} =
  let error = newException(SaleTimeoutError, "Sale cancelled due to timeout")
  return some State(SaleErrored(error: error))
