import ../statemachine

type PurchaseErrored* = ref object of PurchaseState
  error*: ref CatchableError

method enter*(state: PurchaseErrored) =
  without purchase =? (state.context as Purchase):
    raiseAssert "invalid state"

  purchase.future.fail(state.error)

method description*(state: PurchaseErrored): string =
  "errored"
