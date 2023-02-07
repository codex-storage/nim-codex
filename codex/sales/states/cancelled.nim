import ../statemachine
import ./errored

type
  SaleCancelled* = ref object of SaleState
  SaleCancelledError* = object of CatchableError
  SaleTimeoutError* = object of SaleCancelledError

method `$`*(state: SaleCancelled): string = "SaleCancelled"

method enterAsync*(state: SaleCancelled) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  let error = newException(SaleTimeoutError, "Sale cancelled due to timeout")
  await state.switchAsync(SaleErrored(error: error))
