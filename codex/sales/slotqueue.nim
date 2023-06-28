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
    proc(sqi: SlotQueueItem, processing: Future[void]): Future[void] {.gcsafe, upraises:[].}

  SlotQueueWorker = ref object
    processing: Future[void]

  # Non-ref obj copies value when assigned, preventing accidental modification
  # of values which could cause an incorrect order (eg
  # ``slotQueue[1].collateral = 1`` would cause ``collateral`` to be updated,
  # but the heap invariant would no longer be honoured. When non-ref, the
  # compiler can ensure that statement will fail).
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
    workers: seq[SlotQueueWorker]

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

  let mworkers = if maxWorkers == 0'u: DefaultMaxWorkers
                 elif maxWorkers > maxSize: maxSize
                 else: maxWorkers

  SlotQueue(
    # Add 1 to always allow for an extra item to be pushed onto the queue
    # temporarily. After push (and sort), the bottom-most item will be deleted
    queue: newAsyncHeapQueue[SlotQueueItem](maxSize.int + 1),
    maxWorkers: mworkers,
    workers: newSeqOfCap[SlotQueueWorker](mworkers),
    running: false
  )

proc new*(_: type SlotQueueWorker): SlotQueueWorker =
  SlotQueueWorker(
    processing: newFuture[void]("slotqueue.worker.processing")
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
    let sqi = SlotQueueItem.init(requestId, i, ask, expiry)
    inc i
    return sqi

  var sqis = newSeqWith[uint64](ask.slots, initSlotQueueItem())
  Rng.instance.shuffle(sqis)
  return sqis

proc init*(_: type SlotQueueItem,
          request: StorageRequest): seq[SlotQueueItem] =

  return SlotQueueItem.init(request.id, request.ask, request.expiry)

proc requestId*(self: SlotQueueItem): RequestId = self.requestId

proc slotIndex*(self: SlotQueueItem): uint64 = self.slotIndex

proc running*(self: SlotQueue): bool = self.running

proc len*(self: SlotQueue): int = self.queue.len

proc `$`*(self: SlotQueue): string = $self.queue

proc `onProcessSlot=`*(self: SlotQueue, onProcessSlot: OnProcessSlot) =
  self.onProcessSlot = some onProcessSlot

proc activeWorkers*(self: SlotQueue): int = self.workers.len

proc contains*(self: SlotQueue, sqi: SlotQueueItem): bool =
  self.queue.contains(sqi)

proc pop*(self: SlotQueue): Future[?!SlotQueueItem] {.async.} =
  try:
    let sqi = await self.queue.pop()
    return success(sqi)
  except CatchableError as err:
    return failure(err)

proc push*(self: SlotQueue, sqi: SlotQueueItem): ?!void =
  if self.contains(sqi):
    let err = newException(SlotQueueItemExistsError, "item already exists")
    return failure(err)

  if err =? self.queue.pushNoWait(sqi).mapFailure.errorOption:
    return failure(err)

  if self.queue.full():
    # delete the last item
    self.queue.del(self.queue.size - 1)

  doAssert self.queue.len <= self.queue.size
  return success()

proc push*(self: SlotQueue, sqis: seq[SlotQueueItem]): ?!void =
  for sqi in sqis:
    if err =? self.push(sqi).errorOption:
      return failure(err)

  return success()

proc findByRequest(self: SlotQueue, requestId: RequestId): seq[SlotQueueItem] =
  var sqis: seq[SlotQueueItem] = @[]
  for sqi in self.queue.items:
    if sqi.requestId == requestId:
      sqis.add sqi
  return sqis

proc delete*(self: SlotQueue, sqi: SlotQueueItem) =
  self.queue.delete(sqi)

proc delete*(self: SlotQueue, requestId: RequestId, slotIndex: uint64) =
  let sqi = SlotQueueItem(requestId: requestId, slotIndex: slotIndex)
  self.delete(sqi)

proc delete*(self: SlotQueue, requestId: RequestId) =
  let sqis = self.findByRequest(requestId)
  for sqi in sqis:
    self.delete(sqi)

proc get*(self: SlotQueue, requestId: RequestId, slotIndex: uint64): ?!SlotQueueItem =
  let sqi = SlotQueueItem(requestId: requestId, slotIndex: slotIndex)
  let idx = self.queue.find(sqi)
  if idx == -1:
    let err = newException(SlotQueueItemNotExistsError, "item does not exist")
    return failure(err)

  return success(self.queue[idx])

proc `[]`*(self: SlotQueue, i: Natural): SlotQueueItem =
  self.queue[i]

proc dispatch(self: SlotQueue,
              worker: SlotQueueWorker,
              sqi: SlotQueueItem) {.async.} =



  if onProcessSlot =? self.onProcessSlot:
    await onProcessSlot(sqi, worker.processing)
    await worker.processing

  self.workers.keepItIf(it != worker)

proc start*(self: SlotQueue) {.async.} =
  if self.running:
    return

  self.running = true

  proc handleErrors(udata: pointer) {.gcsafe.} =
    var fut = cast[FutureBase](udata)
    if fut.failed() and not fut.error.isNil:
      error "slot queue error encountered during processing",
        error = fut.error.msg

  while self.running: # and self.workers.len.uint < self.maxWorkers:
    if self.workers.len.uint >= self.maxWorkers:
      await sleepAsync(1.millis)
      continue

    try:
      self.next = self.queue.pop()
      self.next.addCallback(handleErrors)
      let sqi = await self.next # if queue empty, should wait here for new items
      let worker = SlotQueueWorker.new()
      self.workers.add worker
      asyncSpawn self.dispatch(worker, sqi)
      self.next = nil
      await sleepAsync(1.millis) # poll
    except CancelledError:
      discard

proc stop*(self: SlotQueue) =
  if not self.running:
    return

  if not self.next.isNil:
    self.next.cancel()

  self.next = nil
  self.running = false

