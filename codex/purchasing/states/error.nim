import ../statemachine

type PurchaseError* = ref object of PurchaseState
  error*: ref CatchableError

method enter*(state: PurchaseError) =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  purchase.future.fail(state.error)
