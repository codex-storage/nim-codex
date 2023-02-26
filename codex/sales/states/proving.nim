import ../statemachine

type
  SaleProving* = ref object of State
  SaleProvingError* = object of SaleError

method `$`*(state: SaleProving): string = "SaleProving"

method run*(state: SaleProving, machine: Machine): Future[?State] {.async.} =
  # echo "running ", state
  let agent = SalesAgent(machine)

  without onProve =? agent.sales.onProve:
    raiseAssert "onProve callback not set"

  without request =? agent.request:
    let error = newException(SaleProvingError, "missing request")
    agent.setError error
    return

  let proof = await onProve(request, agent.slotIndex)
  agent.proof.setValue(proof)
