import ../statemachine
import ./errorhandling
import ./errored
import ../../asyncyeah

type
  SaleCancelled* = ref object of ErrorHandlingState
  SaleCancelledError* = object of CatchableError
  SaleTimeoutError* = object of SaleCancelledError

method `$`*(state: SaleCancelled): string = "SaleCancelled"

method run*(state: SaleCancelled, machine: Machine): Future[?State] {.asyncyeah.} =
  let error = newException(SaleTimeoutError, "Sale cancelled due to timeout")
  return some State(SaleErrored(error: error))
