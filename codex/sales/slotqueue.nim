import std/sequtils
import std/tables
import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import ./reservations
import ../errors
import ../rng
import ../utils
import ../contracts/requests
import ../utils/asyncheapqueue

logScope:
  topics = "marketplace slotqueue"

type
  OnProcessSlot* =
    proc(item: SlotQueueItem): Future[void] {.gcsafe, upraises:[].}


  # Non-ref obj copies value when assigned, preventing accidental modification
  # of values which could cause an incorrect order (eg
  # ``slotQueue[1].collateral = 1`` would cause ``collateral`` to be updated,
  # but the heap invariant would no longer be honoured. When non-ref, the
  # compiler can ensure that statement will fail).
  SlotQueueWorker = object
  SlotQueueItem* = object
    requestId: RequestId
    slotIndex: uint16
    slotSize: UInt256
    duration: UInt256
    reward: UInt256
    collateral: UInt256
    expiry: UInt256
    doneProcessing*: Future[void]

  # don't need to -1 to prevent overflow when adding 1 (to always allow push)
  # because AsyncHeapQueue size is of type `int`, which is larger than `uint16`
  SlotQueueSize = range[1'u16..uint16.high]

  SlotQueue* = ref object
    maxWorkers: int
    next: Future[SlotQueueItem]
    onProcessSlot: ?OnProcessSlot
    queue: AsyncHeapQueue[SlotQueueItem]
    reservations: Reservations
    running: bool
    workers: AsyncQueue[SlotQueueWorker]
    dispatched: Table[uint, Future[void]]

  SlotQueueError = object of CodexError
  SlotQueueItemExistsError* = object of SlotQueueError
  SlotQueueItemNotExistsError* = object of SlotQueueError
  SlotsOutOfRangeError* = object of SlotQueueError
  NoMatchingAvailabilityError* = object of SlotQueueError
  QueueNotRunningError* = object of SlotQueueError

# Number of concurrent workers used for processing SlotQueueItems
const DefaultMaxWorkers = 3

# Cap slot queue size to prevent unbounded growth and make sifting more
# efficient. Max size is not equivalent to the number of slots a host can
# service, which is limited by host availabilities and new requests circulating
# the network. Additionally, each new request/slot in the network will be
# included in the queue if it is higher priority than any of the exisiting
# items. Older slots should be unfillable over time as other hosts fill the
# slots.
const DefaultMaxSize = 64'u16

proc profitability(item: SlotQueueItem): UInt256 =
  StorageAsk(collateral: item.collateral,
             duration: item.duration,
             reward: item.reward,
             slotSize: item.slotSize).pricePerSlot

proc `<`*(a, b: SlotQueueItem): bool =
  a.profitability > b.profitability or  # profitability
  a.collateral < b.collateral or        # collateral required
  a.expiry > b.expiry or                # expiry
  a.slotSize < b.slotSize               # dataset size

proc `==`*(a, b: SlotQueueItem): bool =
  a.requestId == b.requestId and
  a.slotIndex == b.slotIndex

proc new*(_: type SlotQueue,
          reservations: Reservations,
          maxWorkers = DefaultMaxWorkers,
          maxSize: SlotQueueSize = DefaultMaxSize): SlotQueue =

  if maxWorkers <= 0:
    raise newException(ValueError, "maxWorkers must be positive")
  if maxWorkers.uint16 > maxSize:
    raise newException(ValueError, "maxWorkers must be less than maxSize")

  SlotQueue(
    maxWorkers: maxWorkers,
    # Add 1 to always allow for an extra item to be pushed onto the queue
    # temporarily. After push (and sort), the bottom-most item will be deleted
    queue: newAsyncHeapQueue[SlotQueueItem](maxSize.int + 1),
    reservations: reservations,
    running: false
  )
  # avoid instantiating `workers` in constructor to avoid side effects in
  # `newAsyncQueue` procedure

proc init*(_: type SlotQueueWorker): SlotQueueWorker =
  SlotQueueWorker(
    processing: false
  )

proc init*(_: type SlotQueueItem,
          requestId: RequestId,
          slotIndex: uint16,
          ask: StorageAsk,
          expiry: UInt256): SlotQueueItem =

  SlotQueueItem(
    requestId: requestId,
    slotIndex: slotIndex,
    slotSize: ask.slotSize,
    duration: ask.duration,
    reward: ask.reward,
    collateral: ask.collateral,
    expiry: expiry,
    doneProcessing: newFuture[void]("slotqueue.worker.processing")
  )

proc init*(_: type SlotQueueItem,
           request: StorageRequest,
           slotIndex: uint16): SlotQueueItem =

  SlotQueueItem.init(request.id,
                     slotIndex,
                     request.ask,
                     request.expiry)

proc init*(_: type SlotQueueItem,
          requestId: RequestId,
          ask: StorageAsk,
          expiry: UInt256): seq[SlotQueueItem] =

  if not ask.slots.inRange:
    raise newException(SlotsOutOfRangeError, "Too many slots")

  var i = 0'u16
  proc initSlotQueueItem: SlotQueueItem =
    let item = SlotQueueItem.init(requestId, i, ask, expiry)
    inc i
    return item

  var items = newSeqWith(ask.slots.int, initSlotQueueItem())
  Rng.instance.shuffle(items)
  return items

proc init*(_: type SlotQueueItem,
          request: StorageRequest): seq[SlotQueueItem] =

  return SlotQueueItem.init(request.id, request.ask, request.expiry)

proc inRange*(val: SomeUnsignedInt): bool =
  val.uint16 in SlotQueueSize.low..SlotQueueSize.high

proc requestId*(self: SlotQueueItem): RequestId = self.requestId
proc slotIndex*(self: SlotQueueItem): uint16 = self.slotIndex
proc slotSize*(self: SlotQueueItem): UInt256 = self.slotSize
proc duration*(self: SlotQueueItem): UInt256 = self.duration
proc reward*(self: SlotQueueItem): UInt256 = self.reward
proc collateral*(self: SlotQueueItem): UInt256 = self.collateral

proc running*(self: SlotQueue): bool = self.running

proc len*(self: SlotQueue): int = self.queue.len

proc size*(self: SlotQueue): int = self.queue.size - 1

proc `$`*(self: SlotQueue): string = $self.queue

proc `onProcessSlot=`*(self: SlotQueue, onProcessSlot: OnProcessSlot) =
  self.onProcessSlot = some onProcessSlot

proc activeWorkers*(self: SlotQueue): int =
  if not self.running: return 0

  # active = capacity - available
  self.maxWorkers - self.workers.len

proc contains*(self: SlotQueue, item: SlotQueueItem): bool =
  self.queue.contains(item)

proc populateItem*(self: SlotQueue,
                   requestId: RequestId,
                   slotIndex: uint16): ?SlotQueueItem =

  for item in self.queue.items:
    trace "populate item search", itemRequestId = item.requestId, requestId
    if item.requestId == requestId:
      return some SlotQueueItem(
        requestId: requestId,
        slotIndex: slotIndex,
        slotSize: item.slotSize,
        duration: item.duration,
        reward: item.reward,
        collateral: item.collateral,
        expiry: item.expiry,
        doneProcessing: newFuture[void]("slotqueue.worker.processing")
      )
  return none SlotQueueItem

proc pop*(self: SlotQueue): Future[?!SlotQueueItem] {.async.} =
  try:
    let item = await self.queue.pop()
    return success(item)
  except CatchableError as err:
    return failure(err)

proc push*(self: SlotQueue, item: SlotQueueItem): Future[?!void] {.async.} =

  trace "pushing item to queue",
    requestId = item.requestId, slotIndex = item.slotIndex

  without availability =? await self.reservations.find(item.slotSize,
                                                       item.duration,
                                                       item.profitability,
                                                       item.collateral,
                                                       used = false):
    let err = newException(NoMatchingAvailabilityError, "no availability")
    return failure(err)

  if self.contains(item):
    let err = newException(SlotQueueItemExistsError, "item already exists")
    return failure(err)

  if not self.running:
    let err = newException(QueueNotRunningError, "queue not running")
    return failure(err)

  if err =? self.queue.pushNoWait(item).mapFailure.errorOption:
    return failure(err)

  if self.queue.full():
    # delete the last item
    self.queue.del(self.queue.size - 1)

  doAssert self.queue.len <= self.queue.size - 1
  return success()

proc push*(self: SlotQueue, items: seq[SlotQueueItem]): Future[?!void] {.async.} =
  for item in items:
    if err =? (await self.push(item)).errorOption:
      return failure(err)

  return success()

proc findByRequest(self: SlotQueue, requestId: RequestId): seq[SlotQueueItem] =
  var items: seq[SlotQueueItem] = @[]
  for item in self.queue.items:
    if item.requestId == requestId:
      items.add item
  return items

proc delete*(self: SlotQueue, item: SlotQueueItem) =
  logScope:
    requestId = item.requestId
    slotIndex = item.slotIndex

  trace "removing item from queue"

  if not self.running:
    trace "cannot delete item from queue, queue not running"
    return

  self.queue.delete(item)

proc delete*(self: SlotQueue, requestId: RequestId, slotIndex: uint16) =
  let item = SlotQueueItem(requestId: requestId, slotIndex: slotIndex)
  self.delete(item)

proc delete*(self: SlotQueue, requestId: RequestId) =
  let items = self.findByRequest(requestId)
  for item in items:
    self.delete(item)

proc get*(self: SlotQueue, requestId: RequestId, slotIndex: uint16): ?!SlotQueueItem =
  let item = SlotQueueItem(requestId: requestId, slotIndex: slotIndex)
  let idx = self.queue.find(item)
  if idx == -1:
    let err = newException(SlotQueueItemNotExistsError, "item does not exist")
    return failure(err)

  return success(self.queue[idx])

proc `[]`*(self: SlotQueue, i: Natural): SlotQueueItem =
  self.queue[i]

proc addWorker(self: SlotQueue): ?!void =
  if not self.running:
    let err = newException(QueueNotRunningError, "queue must be running")
    return failure(err)

  let worker = SlotQueueWorker()
  try:
    self.workers.addLastNoWait(worker)
  except AsyncQueueFullError:
    return failure("failed to add worker, queue full")

  return success()

proc dispatch(self: SlotQueue,
              worker: SlotQueueWorker,
              item: SlotQueueItem) {.async.} =
  logScope:
    requestId = item.requestId
    slotIndex = item.slotIndex

  if not self.running:
    warn "Could not dispatch worker because queue is not running"
    return

  if onProcessSlot =? self.onProcessSlot:
    try:
      await onProcessSlot(item)
      await item.doneProcessing

      if err =? self.addWorker().errorOption:
        raise err # catch below

    except QueueNotRunningError as e:
      info "could not re-add worker to worker queue, queue not running",
        error = e.msg
    except CancelledError:
      # do not bubble exception up as it is called with `asyncSpawn` which would
      # convert the exception into a `FutureDefect`
      discard
    except CatchableError as e:
      # we don't have any insight into types of errors that `onProcessSlot` can
      # throw because it is caller-defined
      warn "Unknown error processing slot in worker", error = e.msg

proc start*(self: SlotQueue) {.async.} =
  if self.running:
    return

  trace "starting slot queue"

  self.running = true

  # must be called in `start` to avoid sideeffects in `new`
  self.workers = newAsyncQueue[SlotQueueWorker](self.maxWorkers)

  # Add initial workers to the `AsyncHeapQueue`. Once a worker has completed its
  # task, a new worker will be pushed to the queue
  for i in 0..<self.maxWorkers:
    if err =? self.addWorker().errorOption:
      error "start: error adding new worker", error = err.msg

  proc onDispatchComplete(udata: pointer) {.gcsafe.} =
    var fut = cast[FutureBase](udata)
    if fut.finished and self.running:
      self.dispatched.del(fut.id)

  while self.running:
    try:
      let worker = await self.workers.popFirst() # wait for worker to free up
      self.next = self.queue.pop()
      let item = await self.next # if queue empty, wait here for new items
      let dispatched = self.dispatch(worker, item)
      dispatched.addCallback(onDispatchComplete)
      self.dispatched[dispatched.id] = dispatched
      self.next = nil
      await sleepAsync(1.millis) # poll
    except CancelledError:
      discard
    except CatchableError as e: # raised from self.queue.pop() or self.workers.pop()
      warn "slot queue error encountered during processing", error = e.msg

proc stop*(self: SlotQueue) {.async.} =
  if not self.running:
    return

  trace "stopping slot queue"

  self.running = false

  if not self.next.isNil:
    await self.next.cancelAndWait()
    self.next = nil

  for item in self.queue.items:
    if not item.doneProcessing.isNil and not item.doneProcessing.finished():
      await item.doneProcessing.cancelAndWait()

  for dispatched in self.dispatched.values:
    await dispatched.cancelAndWait()


