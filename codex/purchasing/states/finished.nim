import ../statemachine

type PurchaseFinished* = ref object of PurchaseState

method enter*(state: PurchaseFinished) =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  purchase.future.complete()
