import ../utils/statemachine
import ../market
import ../clock

export market
export clock
export statemachine

type
  Purchase* = ref object of StateMachine
    future*: Future[void]
    market*: Market
    clock*: Clock
    request*: StorageRequest
  PurchaseState* = ref object of AsyncState
