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
  OnProcessRequest* =
    proc(rqi: RequestQueueItem, processing: Future[void]): Future[void] {.gcsafe, upraises:[].}

  RequestQueueWorker = ref object
    processing: Future[void]

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

  RequestQueue* = ref object
    queue: AsyncHeapQueue[RequestQueueItem]
    running: bool
    onProcessRequest: ?OnProcessRequest
    next: Future[RequestQueueItem]
    maxWorkers: uint
    workers: seq[RequestQueueWorker]

  RequestQueueError = object of CodexError
  RequestQueueItemExistsError* = object of RequestQueueError
  RequestQueueItemNotExistsError* = object of RequestQueueError

# Number of concurrent workers used for processing RequestQueueItems
const DefaultMaxWorkers = 3'u

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
          maxWorkers = DefaultMaxWorkers,
          maxSize = DefaultMaxSize): RequestQueue =

  let mworkers = if maxWorkers == 0'u: DefaultMaxWorkers
                 else: maxWorkers

  RequestQueue(
    # Add 1 to always allow for an extra item to be pushed onto the queue
    # temporarily. After push (and sort), the bottom-most item will be deleted
    queue: newAsyncHeapQueue[RequestQueueItem](maxSize + 1),
    maxWorkers: mworkers,
    workers: newSeqOfCap[RequestQueueWorker](mworkers),
    running: false
  )

proc new*(_: type RequestQueueWorker): RequestQueueWorker =
  RequestQueueWorker(
    processing: newFuture[void]("requestqueue.worker.processing")
  )

proc init*(_: type RequestQueueItem,
          requestId: RequestId,
          ask: StorageAsk,
          expiry: UInt256,
          availableSlotIndices = none seq[uint64]): RequestQueueItem =
  var rqi = RequestQueueItem(
              requestId: requestId,
              ask: ask,
              expiry: expiry,
              availableSlotIndices: newSeqOfCap[uint64](ask.slots)
            )
  rqi.availableSlotIndices.add availableSlotIndices |? toSeq(0'u64..<ask.slots)
  return rqi

proc init*(_: type RequestQueueItem,
          request: StorageRequest): RequestQueueItem =
  var rqi = RequestQueueItem(
    requestId: request.id,
    ask: request.ask,
    expiry: request.expiry,
    availableSlotIndices: newSeqOfCap[uint64](request.ask.slots)
  )
  rqi.availableSlotIndices.add toSeq(0'u64..<request.ask.slots)
  return rqi

proc running*(self: RequestQueue): bool = self.running

proc len*(self: RequestQueue): int = self.queue.len

proc `$`*(self: RequestQueue): string = $self.queue

proc `onProcessRequest=`*(self: RequestQueue,
                          onProcessRequest: OnProcessRequest) =
  self.onProcessRequest = some onProcessRequest

proc activeWorkers*(self: RequestQueue): int = self.workers.len

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

proc dispatch(self: RequestQueue,
              worker: RequestQueueWorker,
              rqi: RequestQueueItem) {.async.} =



  if onProcessRequest =? self.onProcessRequest:
    await onProcessRequest(rqi, worker.processing)
    await worker.processing

  self.workers.keepItIf(it != worker)

proc start*(self: RequestQueue) {.async.} =
  if self.running:
    return

  self.running = true

  proc handleErrors(udata: pointer) {.gcsafe.} =
    var fut = cast[FutureBase](udata)
    if fut.failed():
      error "request queue error encountered during processing",
        error = fut.error.msg

  while self.running: # and self.workers.len.uint < self.maxWorkers:
    if self.workers.len.uint >= self.maxWorkers:
      await sleepAsync(1.millis)
      continue

    try:
      self.next = self.queue.peek()
      self.next.addCallback(handleErrors)
      let rqi = await self.next # if queue empty, should wait here for new items
      let worker = RequestQueueWorker.new()
      self.workers.add worker
      asyncSpawn self.dispatch(worker, rqi)


      self.next = nil
      await sleepAsync(1.millis) # poll
    except CancelledError:
      discard

proc stop*(self: RequestQueue) =
  if not self.running:
    return

  if not self.next.isNil:
    self.next.cancel()

  self.next = nil
  self.running = false

