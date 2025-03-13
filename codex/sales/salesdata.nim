import pkg/chronos
import ../contracts/requests
import ../market
import ./reservations
import ./slotqueue

type SalesData* = ref object
  requestId*: RequestId
  ask*: StorageAsk
  request*: ?StorageRequest
  slotIndex*: uint64
  cancelled*: Future[void]
  reservation*: ?Reservation
  slotQueueItem*: ?SlotQueueItem
