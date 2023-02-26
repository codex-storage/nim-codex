import ../statemachine

type
  SaleFailed* = ref object of State
  SaleFailedError* = object of SaleError

method `$`*(state: SaleFailed): string = "SaleFailed"

method run*(state: SaleFailed, machine: Machine): Future[?State] {.async.} =
  # echo "running ", state
  let error = newException(SaleFailedError, "Sale failed")
  machine.setError error
