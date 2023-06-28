import std/sequtils
import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import ../errors
import ../rng
import ../utils
import ../contracts/requests
import ../utils/asyncheapqueue

logScope:
  topics = "marketplace slotqueue"

type
  OnProcessSlot* =
    proc(item: SlotQueueItem, processing: Future[void]): Future[void] {.gcsafe, upraises:[].}


  # Non-ref obj copies value when assigned, preventing accidental modification
  # of values which could cause an incorrect order (eg
  # ``slotQueue[1].collateral = 1`` would cause ``collateral`` to be updated,
  # but the heap invariant would no longer be honoured. When non-ref, the
  # compiler can ensure that statement will fail).
  SlotQueueWorker = object
  SlotQueueItem* = object
    requestId: RequestId
    slotIndex: uint64
    ask: StorageAsk
    expiry: UInt256

  SlotQueue* = ref object
    queue: AsyncHeapQueue[SlotQueueItem]
    running: bool
    onProcessSlot: ?OnProcessSlot
    next: Future[SlotQueueItem]
    maxWorkers: uint
    workers: AsyncQueue[SlotQueueWorker]

  SlotQueueError = object of CodexError
  SlotQueueItemExistsError* = object of SlotQueueError
  SlotQueueItemNotExistsError* = object of SlotQueueError

# Number of concurrent workers used for processing SlotQueueItems
const DefaultMaxWorkers = 3'u

# Cap slot queue size to prevent unbounded growth and make sifting more
# efficient. Max size is not equivalent to the number of slots a host can
# service, which is limited by host availabilities and new requests circulating
# the network. Additionally, each new request/slot in the network will be
# included in the queue if it is higher priority than any of the exisiting
# items. Older slots should be unfillable over time as other hosts fill the
# slots.
const DefaultMaxSize = 64'u

proc `<`*(a, b: SlotQueueItem): bool =
  a.ask.pricePerSlot > b.ask.pricePerSlot or # profitability
  a.ask.collateral < b.ask.collateral or     # collateral required
  a.expiry > b.expiry or                     # expiry
  a.ask.slotSize < b.ask.slotSize            # dataset size

proc `==`(a, b: SlotQueueItem): bool =
  a.requestId == b.requestId and
  a.slotIndex == b.slotIndex

proc new*(_: type SlotQueue,
          maxWorkers = DefaultMaxWorkers,
          maxSize = DefaultMaxSize): SlotQueue =

  if maxWorkers == 0'u:
    raise newException(ValueError, "maxWorkers must be positive")
  if maxWorkers > maxSize:
    raise newException(ValueError, "maxWorkers must be less than maxSize")

  SlotQueue(
    # Add 1 to always allow for an extra item to be pushed onto the queue
    # temporarily. After push (and sort), the bottom-most item will be deleted
    queue: newAsyncHeapQueue[SlotQueueItem](maxSize.int + 1),
    maxWorkers: maxWorkers,
    workers: newAsyncQueue[SlotQueueWorker](maxWorkers.int),
    running: false
  )

proc init*(_: type SlotQueueWorker): SlotQueueWorker =
  SlotQueueWorker(
    processing: false
  )

proc init*(_: type SlotQueueItem,
          requestId: RequestId,
          slotIndex: uint64,
          ask: StorageAsk,
          expiry: UInt256): SlotQueueItem =

  SlotQueueItem(
    requestId: requestId,
    slotIndex: slotIndex,
    ask: ask,
    expiry: expiry
  )

proc init*(_: type SlotQueueItem,
           request: StorageRequest,
           slotIndex: uint64): SlotQueueItem =

  SlotQueueItem.init(request.id, slotIndex, request.ask, request.expiry)

proc init*(_: type SlotQueueItem,
          requestId: RequestId,
          ask: StorageAsk,
          expiry: UInt256): seq[SlotQueueItem] =

  var i = 0'u64
  proc initSlotQueueItem: SlotQueueItem =
    let item = SlotQueueItem.init(requestId, i, ask, expiry)
    inc i
    return item

  var items = newSeqWith[uint64](ask.slots, initSlotQueueItem())
  Rng.instance.shuffle(items)
  return items

proc init*(_: type SlotQueueItem,
          request: StorageRequest): seq[SlotQueueItem] =

  return SlotQueueItem.init(request.id, request.ask, request.expiry)

proc requestId*(self: SlotQueueItem): RequestId = self.requestId

proc slotIndex*(self: SlotQueueItem): uint64 = self.slotIndex

proc running*(self: SlotQueue): bool = self.running

proc len*(self: SlotQueue): int = self.queue.len

proc `$`*(self: SlotQueue): string = $self.queue

proc len(i: int): int = i

proc `onProcessSlot=`*(self: SlotQueue, onProcessSlot: OnProcessSlot) =
  self.onProcessSlot = some onProcessSlot

proc activeWorkers*(self: SlotQueue): int =
  # active = capacity - available
  self.workers.size - self.workers.len

proc contains*(self: SlotQueue, item: SlotQueueItem): bool =
  self.queue.contains(item)

proc pop*(self: SlotQueue): Future[?!SlotQueueItem] {.async.} =
  try:
    let item = await self.queue.pop()
    return success(item)
  except CatchableError as err:
    return failure(err)

proc push*(self: SlotQueue, item: SlotQueueItem): ?!void =
  if self.contains(item):
    let err = newException(SlotQueueItemExistsError, "item already exists")
    return failure(err)

  if err =? self.queue.pushNoWait(item).mapFailure.errorOption:
    return failure(err)

  if self.queue.full():
    # delete the last item
    self.queue.del(self.queue.size - 1)

  doAssert self.queue.len <= self.queue.size - 1
  return success()

proc push*(self: SlotQueue, items: seq[SlotQueueItem]): ?!void =
  for item in items:
    if err =? self.push(item).errorOption:
      return failure(err)

  return success()

proc findByRequest(self: SlotQueue, requestId: RequestId): seq[SlotQueueItem] =
  var items: seq[SlotQueueItem] = @[]
  for item in self.queue.items:
    if item.requestId == requestId:
      items.add item
  return items

proc delete*(self: SlotQueue, item: SlotQueueItem) =
  self.queue.delete(item)

proc delete*(self: SlotQueue, requestId: RequestId, slotIndex: uint64) =
  let item = SlotQueueItem(requestId: requestId, slotIndex: slotIndex)
  self.delete(item)

proc delete*(self: SlotQueue, requestId: RequestId) =
  let items = self.findByRequest(requestId)
  for item in items:
    self.delete(item)

proc get*(self: SlotQueue, requestId: RequestId, slotIndex: uint64): ?!SlotQueueItem =
  let item = SlotQueueItem(requestId: requestId, slotIndex: slotIndex)
  let idx = self.queue.find(item)
  if idx == -1:
    let err = newException(SlotQueueItemNotExistsError, "item does not exist")
    return failure(err)

  return success(self.queue[idx])

proc `[]`*(self: SlotQueue, i: Natural): SlotQueueItem =
  self.queue[i]

proc addWorker(self: SlotQueue) =
  let worker = SlotQueueWorker()
  try:
    self.workers.addLastNoWait(worker)
  except AsyncQueueFullError as err:
    error "failed to add worker, queue full", error = err.msg

proc dispatch(self: SlotQueue,
              worker: SlotQueueWorker,
              item: SlotQueueItem) {.async.} =

  let done = newFuture[void]("slotqueue.worker.processing")

  if onProcessSlot =? self.onProcessSlot:
    try:
      await onProcessSlot(item, done)
    except CatchableError as e:
      # we don't have any insight into types of errors that `onProcessSlot` can
      # throw because it is caller-defined
      warn "Unknown error processing slot in worker",
        requestId = item.requestId, error = e.msg

    try:
      await done
    except CancelledError as e:
      # do not bubble exception up as it is called with `asyncSpawn` which would
      # convert the exception into a `FutureDefect`
      discard

  self.addWorker()

proc start*(self: SlotQueue) {.async.} =
  if self.running:
    return

  self.running = true

  # Add initial workers to the `AsyncHeapQueue`. Once a worker has completed its
  # task, a new worker will be pushed to the queue
  for i in 0..<self.workers.size:
    self.addWorker()

  while self.running:
    try:
      let worker = await self.workers.popFirst() # wait for worker to free up
      self.next = self.queue.pop()
      let item = await self.next # if queue empty, wait here for new items
      asyncSpawn self.dispatch(worker, item)
      self.next = nil
      await sleepAsync(1.millis) # poll
    except CancelledError:
      discard
    except CatchableError as e: # raised from self.queue.pop() or self.workers.pop()
      warn "slot queue error encountered during processing", error = e.msg

proc stop*(self: SlotQueue) =
  if not self.running:
    return

  if not self.next.isNil:
    self.next.cancel()

  self.next = nil
  self.running = false

