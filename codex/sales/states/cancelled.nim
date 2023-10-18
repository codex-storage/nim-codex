import pkg/chronicles
import ../statemachine
import ./errorhandling
import ./errored

logScope:
  topics = "marketplace sales cancelled"

type
  SaleCancelled* = ref object of ErrorHandlingState
  SaleCancelledError* = object of CatchableError
  SaleTimeoutError* = object of SaleCancelledError

method `$`*(state: SaleCancelled): string = "SaleCancelled"

method run*(state: SaleCancelled, machine: Machine): Future[?State] {.async.} =
  let error = newException(SaleTimeoutError, "Sale cancelled due to timeout")
  return some State(SaleErrored(error: error))
