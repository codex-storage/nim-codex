import ../statemachine
import ./errored

type SaleCancelled* = ref object of SaleState

method `$`*(state: SaleCancelled): string = "SaleCancelled"

method enterAsync*(state: SaleCancelled) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  let error = newException(Timeout, "Sale cancelled due to timeout")
  await state.switchAsync(SaleErrored(error: error))
