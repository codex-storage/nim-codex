import pkg/chronos
import ../contracts/requests
import ../market
import ./availability

type
  SalesData* = ref object
    requestId*: RequestId
    ask*: StorageAsk
    availability*: ?Availability # TODO: when availability persistence is added, change this to not optional
    request*: ?StorageRequest
    slotIndex*: UInt256
    failed*: market.Subscription
    fulfilled*: market.Subscription
    slotFilled*: market.Subscription
    cancelled*: Future[void]
