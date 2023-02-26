import ../statemachine
import ../subscriptions

type
  SaleUnknown* = ref object of State
  SaleUnknownError* = object of SaleError
  UnexpectedSlotError* = object of SaleUnknownError

method `$`*(state: SaleUnknown): string = "SaleUnknown"

method run*(state: SaleUnknown, machine: Machine): Future[?State] {.async.} =
  # echo "running ", state
  let agent = SalesAgent(machine)
  let market = agent.sales.market

  if agent.request.isNone:
    agent.request = await market.getRequest(agent.requestId)
    if agent.request.isSome:
      await agent.subscribe()

  if agent.request.isNone:
    agent.setError newException(SaleUnknownError, "missing request")
    return

  if agent.restoredFromChain and agent.slotState.value == SlotState.Free:
    agent.setError newException(UnexpectedSlotError,
      "slot state on chain should not be 'free'")
    return

