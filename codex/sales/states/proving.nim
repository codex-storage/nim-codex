import ../statemachine
import ./filling
import ./cancelled
import ./failed
import ./filled
import ./errored

type
  SaleProving* = ref object of State
  SaleProvingError* = object of CatchableError

method `$`*(state: SaleProving): string = "SaleProving"

method run*(state: SaleProving, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)

  try:
    without onProve =? agent.sales.onProve:
      raiseAssert "onProve callback not set"

    let proof = await onProve(agent.request, agent.slotIndex)
    agent.proof.setValue(proof)

  except CancelledError:
    raise
