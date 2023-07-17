import pkg/questionable
import ../statemachine
import ./errored
import ../../asyncyeah

type
  ErrorHandlingState* = ref object of SaleState

method onError*(state: ErrorHandlingState, error: ref CatchableError): ?State =
  some State(SaleErrored(error: error))
