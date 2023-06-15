import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import ../errors
import ../contracts/requests
import ../utils/asyncheapqueue

logScope:
  topics = "marketplace requestqueue"

type
  OnProcessRequest* = proc(rqi: RequestQueueItem) {.gcsafe, upraises:[].}
  RequestQueue* = ref object # of AsyncHeapQueue[RequestQueueItem]
    queue: AsyncHeapQueue[RequestQueueItem]
    running: bool
    onProcessRequest: ?OnProcessRequest
    next: Future[RequestQueueItem]

  # Non-ref obj copies value when assigned, preventing accidental modification
  # of values which could cause an incorrect order (eg
  # ``requestQueue[1].collateral = 1`` would cause ``collateral`` to be updated,
  # but the heap invariant would no longer be honoured. When non-ref, the
  # compiler can ensure that statement will fail).
  RequestQueueItem* = object
    requestId*: RequestId
    ask*: StorageAsk
    expiry*: UInt256
    slotIndexSample*: seq[UInt256]

  RequestQueueError = object of CodexError
  RequestQueueEmptyError = object of RequestQueueError

# Cap request queue size to prevent unbounded growth and make sifting more
# efficient. Max size is not equivalent to the number of requests a host can
# service, which is limited by host availabilities and new requests circulating
# the network. Additionally, each new request in the network will be included in
# the queue if it is higher priority than any of the exisiting items. Older
# requests should be unfillable over time as other hosts fill the slots.
const DefaultMaxSize = 64

proc `<`(a, b: RequestQueueItem): bool =
  a.ask.pricePerSlot > b.ask.pricePerSlot or # profitability
  a.ask.collateral < b.ask.collateral or     # collateral required
  a.expiry > b.expiry or                     # expiry
  a.ask.slotSize < b.ask.slotSize            # dataset size

proc `==`(a, b: RequestQueueItem): bool = a.requestId == b.requestId

proc new*(_: type RequestQueue,
          maxSize = DefaultMaxSize): RequestQueue =

  RequestQueue(
    # Add 1 to always allow for an extra item to be pushed onto the queue
    # temporarily. After push (and sort), the bottom-most item will be deleted
    queue: newAsyncHeapQueue[RequestQueueItem](maxSize + 1),
    running: false
  )

proc init*(_: type RequestQueueItem,
          requestId: RequestId,
          ask: StorageAsk,
          expiry: UInt256,
          slotIndexSample: seq[UInt256] = @[]): RequestQueueItem =
  RequestQueueItem(
    requestId: requestId,
    ask: ask,
    expiry: expiry,
    slotIndexSample: slotIndexSample)

proc init*(_: type RequestQueueItem,
          request: StorageRequest): RequestQueueItem =
  RequestQueueItem(
    requestId: request.id,
    ask: request.ask,
    expiry: request.expiry,
    slotIndexSample: @[])

proc running*(self: RequestQueue): bool = self.running

proc len*(self: RequestQueue): int = self.queue.len

proc `$`*(self: RequestQueue): string = $self.queue

proc `onProcessRequest=`*(self: RequestQueue,
                            onProcessRequest: OnProcessRequest) =
  self.onProcessRequest = some onProcessRequest

proc peek*(self: RequestQueue): Future[?!RequestQueueItem] {.async.} =
  try:
    let rqi = await self.queue.peek()
    return success(rqi)
  except CatchableError as cerr:
    return failure(cerr)

proc pushOrUpdate*(self: RequestQueue, rqi: RequestQueueItem) =
  if err =? self.queue.pushOrUpdateNoWait(rqi).errorOption:
    raiseAssert "request queue should not be full"

  if self.queue.full():
    # delete the last item
    self.queue.del(self.queue.size - 1)

  doAssert self.queue.len <= self.queue.size


proc delete*(self: RequestQueue, rqi: RequestQueueItem) =
  self.queue.delete(rqi)

# proc add*(self: RequestQueue, rqi: RequestQueueItem) {.async.} =
#   await self.push(rqi)

# proc remove*(self: RequestQueue, requestId: RequestId): ?!void =
#   ## Removes a request from the queue in O(n) time
#   let idx = self.find(RequestQueueItem(requestId: requestId))
#   if idx == -1:
#     let err = newException(RequestQueueItemNotFoundError,
#       "Request does not exist in queue")
#     return failure(err)

#   self.del(idx)

# proc update*(self: RequestQueue,
#              requestId: RequestId
#              slotIndexSample: seq[UInt256] = @[]): ?!void =
#   ## Updates a request from the queue in O(n) time
#   ## An option to update the queue in O(1) time would be to make the
#   ## ``RequestQueueItems`` refs, however this opens up issues where a queue
#   ## item ref could be stored/passed around and inadvertantly updated which
#   ## would not maintain the HeapQueue invariant.
#   let idx = self.find(RequestQueueItem(requestId: requestId))
#   if idx == -1:
#     let err = newException(RequestQueueItemNotFoundError,
#       "Request does not exist in queue")
#     return failure(err)

#   let copy = self[idx]
#   self.del(idx)
#   copy.slotIndexSample = slotIndexSample
#   self.push(copy)

proc start*(self: RequestQueue) {.async.} =
  if self.running:
    return

  self.running = true

  proc handleErrors(udata: pointer) {.gcsafe.} =
    var fut = cast[FutureBase](udata)
    if fut.failed():
      error "request queue error encountered during processing",
        error = fut.error.msg

  while self.running:
    try:
      self.next = self.queue.peek()
      self.next.addCallback(handleErrors)
      let rqi = await self.next # if queue empty, should wait here for new items
      if onProcessRequest =? self.onProcessRequest:
        onProcessRequest(rqi)
      self.next = nil
      await sleepAsync(1.millis) # give away async control
    except CancelledError:
      discard

proc stop*(self: RequestQueue) =
  if not self.running:
    return

  if not self.next.isNil:
    self.next.cancel()

  self.next = nil
  self.running = false

