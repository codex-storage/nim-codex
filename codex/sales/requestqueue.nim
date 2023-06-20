import std/sequtils
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
    availableSlotIndices*: seq[uint64]

  RequestQueueError = object of CodexError
  RequestQueueItemExistsError* = object of RequestQueueError
  RequestQueueItemNotExistsError* = object of RequestQueueError

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
          availableSlotIndices = none seq[uint64]): RequestQueueItem =
  RequestQueueItem(
    requestId: requestId,
    ask: ask,
    expiry: expiry,
    availableSlotIndices: availableSlotIndices |? toSeq(0'u64..<ask.slots))

proc init*(_: type RequestQueueItem,
          request: StorageRequest): RequestQueueItem =
  RequestQueueItem(
    requestId: request.id,
    ask: request.ask,
    expiry: request.expiry,
    availableSlotIndices: toSeq(0'u64..<request.ask.slots))

proc running*(self: RequestQueue): bool = self.running

proc len*(self: RequestQueue): int = self.queue.len

proc `$`*(self: RequestQueue): string = $self.queue

proc `onProcessRequest=`*(self: RequestQueue,
                          onProcessRequest: OnProcessRequest) =
  self.onProcessRequest = some onProcessRequest

proc contains*(self: RequestQueue, rqi: RequestQueueItem): bool =
  self.queue.contains(rqi)

proc peek*(self: RequestQueue): Future[?!RequestQueueItem] {.async.} =
  try:
    let rqi = await self.queue.peek()
    return success(rqi)
  except CatchableError as err:
    return failure(err)

proc push*(self: RequestQueue, rqi: RequestQueueItem): ?!void =
  if self.contains(rqi):
    let err = newException(RequestQueueItemExistsError,
      "item already exists")
    return failure(err)

  if err =? self.queue.pushNoWait(rqi).mapFailure.errorOption:
    return failure(err)

  if self.queue.full():
    # delete the last item
    self.queue.del(self.queue.size - 1)

  doAssert self.queue.len <= self.queue.size
  return success()

proc pushOrUpdate*(self: RequestQueue, rqi: RequestQueueItem): ?!void =
  if err =? self.queue.pushOrUpdateNoWait(rqi).errorOption:
    return failure("request queue should not be full")

  if self.queue.full():
    # delete the last item
    self.queue.del(self.queue.size - 1)

  doAssert self.queue.len <= self.queue.size
  return success()

proc delete*(self: RequestQueue, rqi: RequestQueueItem) =
  self.queue.delete(rqi)

proc delete*(self: RequestQueue, requestId: RequestId) =
  let rqi = RequestQueueItem(requestId: requestId)
  self.delete(rqi)

proc get*(self: RequestQueue, requestId: RequestId): ?!RequestQueueItem =
  let rqi = RequestQueueItem(requestId: requestId)
  let idx = self.queue.find(rqi)
  if idx == -1:
    let err = newException(RequestQueueItemNotExistsError,
      "item does not exist")
    return failure(err)

  return success(self.queue[idx])

proc addAvailableSlotIndex*(self: RequestQueue,
                            rqi: RequestQueueItem,
                            slotIndex: uint64): ?!void =

  let idx = self.queue.find(rqi)
  var item = rqi # copy
  let found = idx > -1
  let inbounds = slotIndex < item.ask.slots - 1

  if found:
    item = self.queue[idx]
    if inbounds and # slot index oob for request
       slotIndex notin item.availableSlotIndices:
      item.availableSlotIndices.add slotIndex
      discard self.queue.update(item)

  elif inbounds:
    item.availableSlotIndices = @[slotIndex]
    return self.push(item)

  return success()

proc removeAvailableSlotIndex*(self: RequestQueue,
                               requestId: RequestId,
                               slotIndex: uint64): ?!void =

  var rqi = RequestQueueItem(requestId: requestId)
  let idx = self.queue.find(rqi)
  if idx > -1:
    rqi = self.queue[idx]

    if not rqi.availableSlotIndices.contains(slotIndex):
      return success()

    rqi.availableSlotIndices.keepItIf(it != slotIndex)

    # del (at index) then push, avoids a re-find
    self.queue.del(idx)

    if rqi.availableSlotIndices.len > 0:
      # only re-push if there are available slots to fill
      return self.push(rqi)

    return success()


proc `[]`*(self: RequestQueue, i: Natural): RequestQueueItem =
  self.queue[i]

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

