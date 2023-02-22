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

proc unsubscribe*(data: SalesData) {.async.} =
  try:
    if not data.fulfilled.isNil:
      await data.fulfilled.unsubscribe()
  except CatchableError:
    discard
  try:
    if not data.failed.isNil:
      await data.failed.unsubscribe()
  except CatchableError:
    discard
  try:
    if not data.slotFilled.isNil:
      await data.slotFilled.unsubscribe()
  except CatchableError:
    discard
  if not data.cancelled.isNil:
    await data.cancelled.cancelAndWait()

