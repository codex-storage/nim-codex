import ../statemachine

type PurchaseStarted* = ref object of PurchaseState

method enter*(state: PurchaseStarted) =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  purchase.future.complete()
