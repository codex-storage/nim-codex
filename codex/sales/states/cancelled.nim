import ../statemachine

type
  SaleCancelled* = ref object of State
  SaleCancelledError* = object of SaleError
  SaleTimeoutError* = object of SaleCancelledError

method `$`*(state: SaleCancelled): string = "SaleCancelled"

method run*(state: SaleCancelled, machine: Machine): Future[?State] {.async.} =
  # echo "running ", state
  let error = newException(SaleTimeoutError, "Sale cancelled due to timeout")
  machine.setError(error)
