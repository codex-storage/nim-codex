import ./errored
import ../statemachine

type
  SaleFailed* = ref object of SaleState
  SaleFailedError* = object of SaleError

method `$`*(state: SaleFailed): string = "SaleFailed"

method enterAsync*(state: SaleFailed) {.async.} =
  let error = newException(SaleFailedError, "Sale failed")
  await state.switchAsync(SaleErrored(error: error))
