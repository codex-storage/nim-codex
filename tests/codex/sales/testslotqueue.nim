import std/sequtils
import pkg/asynctest
import pkg/chronicles
import pkg/chronos
import pkg/datastore
import pkg/questionable
import pkg/questionable/results

import pkg/codex/sales/reservations
import pkg/codex/sales/slotqueue
import pkg/codex/stores

import ../helpers/mockmarket
import ../helpers/eventually
import ../examples

suite "Slot queue start/stop":

  var repo: RepoStore
  var repoDs: Datastore
  var metaDs: SQLiteDatastore
  var reservations: Reservations
  var queue: SlotQueue

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    repo = RepoStore.new(repoDs, metaDs)
    reservations = Reservations.new(repo)
    queue = SlotQueue.new(reservations)

  teardown:
    await queue.stop()

  test "starts out not running":
    check not queue.running

  test "can call start multiple times, and when already running":
    asyncSpawn queue.start()
    asyncSpawn queue.start()
    check queue.running

  test "can call stop when alrady stopped":
    await queue.stop()
    check not queue.running

  test "can call stop when running":
    asyncSpawn queue.start()
    await queue.stop()
    check not queue.running

  test "can call stop multiple times":
    asyncSpawn queue.start()
    await queue.stop()
    await queue.stop()
    check not queue.running

suite "Slot queue workers":

  var repo: RepoStore
  var repoDs: Datastore
  var metaDs: SQLiteDatastore
  var availability: Availability
  var reservations: Reservations
  var queue: SlotQueue

  proc onProcessSlot(item: SlotQueueItem) {.async.} =
    await sleepAsync(1000.millis)
    # this is not illustrative of the realistic scenario as the
    # `doneProcessing` future would be passed to another context before being
    # completed and therefore is not as simple as making the callback async
    item.doneProcessing.complete()

  setup:
    let request = StorageRequest.example
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    let quota = request.ask.slotSize.truncate(uint) * 100 + 1
    repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = quota)
    reservations = Reservations.new(repo)
    # create an availability that should always match
    availability = Availability.init(
      size = request.ask.slotSize * 100,
      duration = request.ask.duration * 100,
      minPrice = request.ask.pricePerSlot div 100,
      maxCollateral = request.ask.collateral * 100
    )
    queue = SlotQueue.new(reservations, maxSize = 5, maxWorkers = 3)
    queue.onProcessSlot = onProcessSlot
    discard await reservations.reserve(availability)

  proc startQueue = asyncSpawn queue.start()

  teardown:
    await queue.stop()

  test "activeWorkers should be 0 when not running":
    check queue.activeWorkers == 0

  test "maxWorkers cannot be 0":
    expect ValueError:
      discard SlotQueue.new(reservations, maxSize = 1, maxWorkers = 0)

  test "maxWorkers cannot surpass maxSize":
    expect ValueError:
      discard SlotQueue.new(reservations, maxSize = 1, maxWorkers = 2)

  test "does not surpass max workers":
    startQueue()
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check (await queue.push(item1)).isOk
    check (await queue.push(item2)).isOk
    check (await queue.push(item3)).isOk
    check (await queue.push(item4)).isOk
    check eventually queue.activeWorkers == 3

  test "discards workers once processing completed":
    proc processSlot(item: SlotQueueItem) {.async.} =
      await sleepAsync(1.millis)
      item.doneProcessing.complete()

    queue.onProcessSlot = processSlot

    startQueue()
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check (await queue.push(item1)).isOk # finishes after 1.millis
    check (await queue.push(item2)).isOk # finishes after 1.millis
    check (await queue.push(item3)).isOk # finishes after 1.millis
    check (await queue.push(item4)).isOk
    check eventually queue.activeWorkers == 1

suite "Slot queue":

  var onProcessSlotCalled = false
  var onProcessSlotCalledWith: seq[(RequestId, uint16)]
  var repo: RepoStore
  var repoDs: Datastore
  var metaDs: SQLiteDatastore
  var availability: Availability
  var reservations: Reservations
  var queue: SlotQueue
  let maxWorkers = 2
  var unpauseQueue: Future[void]
  var paused: bool

  proc onProcessSlot(item: SlotQueueItem) {.async.} =
    if paused:
      try:
        await unpauseQueue
      except CancelledError:
        return
    trace "processing item", requestId = item.requestId, slotIndex = item.slotIndex
    onProcessSlotCalled = true
    onProcessSlotCalledWith.add (item.requestId, item.slotIndex)
    item.doneProcessing.complete()

  setup:
    onProcessSlotCalled = false
    onProcessSlotCalledWith = @[]
    let request = StorageRequest.example
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    let quota = request.ask.slotSize.truncate(uint) * 100 + 1
    repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = quota)
    reservations = Reservations.new(repo)
    # create an availability that should always match
    availability = Availability.init(
      size = request.ask.slotSize * 100,
      duration = request.ask.duration * 100,
      minPrice = request.ask.pricePerSlot div 100,
      maxCollateral = request.ask.collateral * 100
    )
    queue = SlotQueue.new(reservations, maxSize = 2, maxWorkers = maxWorkers)
    queue.onProcessSlot = onProcessSlot
    paused = false
    unpauseQueue = newFuture[void]("queue.pause")
    discard await reservations.reserve(availability)

    asyncSpawn queue.start()

  teardown:
    if not unpauseQueue.finished:
      await unpauseQueue.cancelAndWait()
      unpauseQueue = nil

    await queue.stop()

  proc pauseAndSaturateWorkers() {.async.} =
    paused = true

    for i in 0..<maxWorkers:
      let item = SlotQueueItem.example
      check isOk await queue.push(item)

    await sleepAsync(1.millis) # poll to allow loop

  proc unpause() =
    paused = false
    unpauseQueue.complete()

  test "starts out empty":
    check queue.len == 0
    check $queue == "[]"

  test "reports correct size":
    check queue.size == 2

  test "correctly compares SlotQueueItems":
    var requestA = StorageRequest.example
    requestA.ask.duration = 1.u256
    requestA.ask.reward = 1.u256
    check requestA.ask.pricePerSlot == 1.u256
    requestA.ask.collateral = 100000.u256
    requestA.expiry = 1001.u256

    var requestB = StorageRequest.example
    requestB.ask.duration = 100.u256
    requestB.ask.reward = 1000.u256
    check requestB.ask.pricePerSlot == 100000.u256
    requestB.ask.collateral = 1.u256
    requestB.expiry = 1000.u256

    let itemA = SlotQueueItem.init(requestA, 0)
    let itemB = SlotQueueItem.init(requestB, 0)
    check itemB < itemA

  test "expands available all possible slot indices on init":
    let request = StorageRequest.example
    let items = SlotQueueItem.init(request)
    check items.len.uint64 == request.ask.slots
    var checked = 0
    for slotIndex in 0'u16..<request.ask.slots.uint16:
      check items.anyIt(it == SlotQueueItem.init(request, slotIndex))
      inc checked
    check checked == items.len

  test "can add items":
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    check (await queue.push(item1)).isOk
    check (await queue.push(item2)).isOk
    check eventually onProcessSlotCalledWith == @[
      (item1.requestId, item1.slotIndex),
      (item2.requestId, item2.slotIndex)
    ]

  test "populates item with exisiting request metadata":
    await pauseAndSaturateWorkers()
    let item = SlotQueueItem.example
    check (await queue.push(item)).isOk
    let populated = !queue.populateItem(item.requestId, 12'u16)
    check populated.requestId == item.requestId
    check populated.slotIndex == 12'u16
    check populated.slotSize == item.slotSize
    check populated.duration == item.duration
    check populated.reward == item.reward
    check populated.collateral == item.collateral

  test "does not find exisiting request metadata":
    let item = SlotQueueItem.example
    check queue.populateItem(item.requestId, 12'u16).isNone

  test "can support uint16.high slots":
    var request = StorageRequest.example
    let maxUInt16 = uint16.high
    let uint64Slots = uint64(maxUInt16)
    request.ask.slots = uint64Slots
    let items = SlotQueueItem.init(request.id, request.ask, request.expiry)
    check items.len.uint16 == maxUInt16

  test "cannot support greater than uint16.high slots":
    var request = StorageRequest.example
    let int32Slots = uint16.high.int32 + 1
    let uint64Slots = uint64(int32Slots)
    request.ask.slots = uint64Slots
    expect SlotsOutOfRangeError:
      discard SlotQueueItem.init(request.id, request.ask, request.expiry)

  test "cannot push duplicate items":
    await pauseAndSaturateWorkers()
    let item = SlotQueueItem.example
    check (await queue.push(item)).isOk
    check (await queue.push(item)).error of SlotQueueItemExistsError
    unpause()
    check eventually (
      onProcessSlotCalledWith.count((item.requestId, item.slotIndex)) == 1
    )

  test "can add items past max maxSize":
    await pauseAndSaturateWorkers()
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check (await queue.push(item1)).isOk
    check (await queue.push(item2)).isOk
    check (await queue.push(item3)).isOk
    check (await queue.push(item4)).isOk
    check queue.len == 2

  test "can pop the topmost item in the queue":
    await pauseAndSaturateWorkers()
    let item = SlotQueueItem.example
    check (await queue.push(item)).isOk
    without top =? await queue.pop():
      fail()
    check top == item

  test "pop waits for push when empty":
    await pauseAndSaturateWorkers()
    let item = SlotQueueItem.example
    proc delayPush(item: SlotQueueItem) {.async.} =
      await sleepAsync(2.millis)
      check (await queue.push(item)).isOk
      return

    asyncSpawn item.delayPush
    without top =? await queue.pop():
      fail()
    check top == item

  test "can delete items":
    await pauseAndSaturateWorkers()
    let item = SlotQueueItem.example
    check (await queue.push(item)).isOk
    queue.delete(item)
    check queue.len == 0

  test "can delete item by request id and slot id":
    await pauseAndSaturateWorkers()
    let items = SlotQueueItem.init(StorageRequest.example)
    check (await queue.push(items)).isOk
    check queue.len == 2
    queue.delete(items[0].requestId, items[0].slotIndex)
    check queue.len == 1

  test "can delete all items by request id":
    await pauseAndSaturateWorkers()
    let items = SlotQueueItem.init(StorageRequest.example)
    check (await queue.push(items)).isOk
    check queue.len == 2 # maxSize == 2
    queue.delete(items[0].requestId)
    check queue.len == 0

  test "can check if contains item":
    await pauseAndSaturateWorkers()
    let item = SlotQueueItem.example
    check queue.contains(item) == false
    check (await queue.push(item)).isOk
    check queue.contains(item)

  test "can get item":
    await pauseAndSaturateWorkers()
    let item = SlotQueueItem.example
    check queue.get(item.requestId, item.slotIndex).error of SlotQueueItemNotExistsError
    check (await queue.push(item)).isOk
    without itm =? queue.get(item.requestId, item.slotIndex):
      fail()
    check item == itm

  test "sorts items by profitability ascending (higher pricePerSlot = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.ask.reward += 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    check (await queue.push(item0)).isOk
    check (await queue.push(item1)).isOk
    check queue[0] == item1

  test "sorts items by collateral ascending (less required collateral = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.ask.collateral -= 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    check (await queue.push(item0)).isOk
    check (await queue.push(item1)).isOk
    check queue[0] == item1

  test "sorts items by expiry descending (longer expiry = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.expiry += 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    check (await queue.push(item0)).isOk
    check (await queue.push(item1)).isOk
    check queue[0] == item1

  test "sorts items by slot size ascending (smaller dataset = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.ask.slotSize -= 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    check (await queue.push(item0)).isOk
    check (await queue.push(item1)).isOk
    check queue[0] == item1

  test "should call callback once an item is added":
    let item = SlotQueueItem.example
    check not onProcessSlotCalled
    check (await queue.push(item)).isOk
    check eventually onProcessSlotCalled

  test "should only process item once":
    let item = SlotQueueItem.example

    check (await queue.push(item)).isOk

    check eventually onProcessSlotCalledWith == @[
      (item.requestId, item.slotIndex)
    ]

  test "should process items in correct order":
    # sleeping after push allows the slotqueue loop to iterate,
    # calling the callback for each pushed/updated item
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.ask.reward += 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    request.ask.reward += 1.u256
    let item2 = SlotQueueItem.init(request, 2)
    request.ask.reward += 1.u256
    let item3 = SlotQueueItem.init(request, 3)

    check (await queue.push(item0)).isOk
    await sleepAsync(1.millis)
    check (await queue.push(item1)).isOk
    await sleepAsync(1.millis)
    check (await queue.push(item2)).isOk
    await sleepAsync(1.millis)
    check (await queue.push(item3)).isOk

    check eventually (
      onProcessSlotCalledWith == @[
        (item0.requestId, item0.slotIndex),
        (item1.requestId, item1.slotIndex),
        (item2.requestId, item2.slotIndex),
        (item3.requestId, item3.slotIndex),
      ]
    )

  test "fails to push when there's no matching availability":
    discard await reservations.release(availability.id,
                    availability.size.truncate(uint))

    let item = SlotQueueItem.example
    check (await queue.push(item)).error of NoMatchingAvailabilityError
