import pkg/chronos
import ../contracts/requests
import ../market
import ./reservations

type
  SalesData* = ref object
    requestId*: RequestId
    ask*: StorageAsk
    request*: ?StorageRequest
    slotIndex*: UInt256
    failed*: market.Subscription
    fulfilled*: market.Subscription
    slotFilled*: market.Subscription
    cancelled*: Future[void]
