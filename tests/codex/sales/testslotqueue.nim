import std/sequtils
import pkg/asynctest
import pkg/chronos
import pkg/chronicles
import pkg/codex/sales/slotqueue
import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import ../helpers/mockmarket
import ../helpers/eventually
import ../examples

suite "Slot queue start/stop":

  var sq: SlotQueue

  setup:
    sq = SlotQueue.new()

  teardown:
    sq.stop()

  test "starts out not running":
    check not sq.running

  test "can call start multiple times, and when already running":
    asyncSpawn sq.start()
    asyncSpawn sq.start()
    check sq.running

  test "can call stop when alrady stopped":
    sq.stop()
    check not sq.running

  test "can call stop when running":
    asyncSpawn sq.start()
    sq.stop()
    check not sq.running

  test "can call stop multiple times":
    asyncSpawn sq.start()
    sq.stop()
    sq.stop()
    check not sq.running

suite "Slot queue workers":

  var sq: SlotQueue

  proc onProcessSlot(item: SlotQueueItem, processing: Future[void]) {.async.} =
    try:
      await sleepAsync(1000.millis)
      # this is not illustrative of the realistic scenario as the `processing`
      # future would be passed to another context before being completed and
      # therefore is not as simple as making the callback async
      processing.complete()
    except Exception:
      discard

  setup:
    sq = SlotQueue.new(maxSize = 5, maxWorkers = 3)
    sq.onProcessSlot = onProcessSlot
    asyncSpawn sq.start()

  teardown:
    sq.stop()

  test "activeWorkers should be 0 when not running":
    sq.stop()
    check sq.activeWorkers == 0

  test "maxWorkers cannot be 0":
    expect ValueError:
      let sq2 = SlotQueue.new(maxSize = 1, maxWorkers = 0)

  test "maxWorkers cannot surpass maxSize":
    expect ValueError:
      let sq2 = SlotQueue.new(maxSize = 1, maxWorkers = 2)

  test "does not surpass max workers":
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check sq.push(item1).isOk
    check sq.push(item2).isOk
    check sq.push(item3).isOk
    check sq.push(item4).isOk
    check eventually sq.activeWorkers == 3'u

  test "discards workers once processing completed":
    proc processSlot(item: SlotQueueItem, processing: Future[void]) {.async.} =
      try:
        await sleepAsync(1.millis)
        processing.complete()
      except Exception:
        discard
    sq.onProcessSlot = processSlot
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check sq.push(item1).isOk # finishes after 1.millis
    check sq.push(item2).isOk # finishes after 1.millis
    check sq.push(item3).isOk # finishes after 1.millis
    check sq.push(item4).isOk
    check eventually sq.activeWorkers == 1'u

suite "Slot queue":

  var sq: SlotQueue
  var onProcessSlotCalled = false
  var onProcessSlotCalledWith: seq[(RequestId, uint64)]

  proc onProcessSlot(item: SlotQueueItem, processing: Future[void]) {.async.} =
    onProcessSlotCalled = true
    onProcessSlotCalledWith.add (item.requestId, item.slotIndex)
    processing.complete()

  setup:
    onProcessSlotCalled = false
    onProcessSlotCalledWith = @[]
    sq = SlotQueue.new(maxSize = 2, maxWorkers = 2)
    sq.onProcessSlot = onProcessSlot
    asyncSpawn sq.start()

  teardown:
    sq.stop()

  test "starts out empty":
    check sq.len == 0
    check $sq == "[]"

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

    let itemA = SlotQueueItem.init(requestA, 0'u64)
    let itemB = SlotQueueItem.init(requestB, 0'u64)
    check itemB < itemA

  test "expands available all possible slot indices on init":
    let request = StorageRequest.example
    let items = SlotQueueItem.init(request)
    check items.len.uint64 == request.ask.slots
    var slotIndices = toSeq(0'u64..<request.ask.slots);
    for slotIndex in 0'u64..<request.ask.slots:
      check items.anyIt(it == SlotQueueItem.init(request, slotIndex))
      slotIndices.delete(slotIndex)
    check slotIndices.len == 0

  test "can add items":
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    check sq.push(item1).isOk
    check sq.push(item2).isOk
    check sq.len == 2

  test "cannot push duplicate items":
    let item = SlotQueueItem.example
    check sq.push(item).isOk
    check sq.push(item).error of SlotQueueItemExistsError
    check sq.len == 1

  test "can add items past max size":
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check sq.push(item1).isOk
    check sq.push(item2).isOk
    check sq.push(item3).isOk
    check sq.push(item4).isOk
    check sq.len == 2

  test "can pop the topmost item in the queue":
    let item = SlotQueueItem.example
    check sq.push(item).isOk
    without top =? await sq.pop():
      fail()
    check top == item

  test "pop waits for push when empty":
    sq.stop() # otherwise .pop in `start` seems to take precedent
    let item = SlotQueueItem.example
    proc delayPush(item: SlotQueueItem) {.async.} =
      await sleepAsync(2.millis)
      check sq.push(item).isOk
      return

    asyncSpawn item.delayPush
    without top =? await sq.pop():
      fail()
    check top == item

  test "can delete items":
    let item = SlotQueueItem.example
    check sq.push(item).isOk
    sq.delete(item)
    check sq.len == 0

  test "can delete item by request id and slot id":
    let items = SlotQueueItem.init(StorageRequest.example)
    check sq.push(items).isOk
    check sq.len == 2 # maxsize == 2
    sq.delete(items[0].requestId, items[0].slotIndex)
    check sq.len == 1

  test "can delete all items by request id":
    let items = SlotQueueItem.init(StorageRequest.example)
    check sq.push(items).isOk
    check sq.len == 2 # maxsize == 2
    sq.delete(items[0].requestId)
    check sq.len == 0

  test "can check if contains item":
    let item = SlotQueueItem.example
    check sq.contains(item) == false
    check sq.push(item).isOk
    check sq.contains(item)

  test "can get item":
    let item = SlotQueueItem.example
    check sq.get(item.requestId, item.slotIndex).error of SlotQueueItemNotExistsError
    check sq.push(item).isOk
    without itm =? sq.get(item.requestId, item.slotIndex):
      fail()
    check item == itm

  test "sorts items by profitability ascending (higher pricePerSlot = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0'u64)
    request.ask.reward += 1.u256
    let item1 = SlotQueueItem.init(request, 1'u64)
    check sq.push(item0).isOk
    check sq.push(item1).isOk
    check sq[0] == item1

  test "sorts items by collateral ascending (less required collateral = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0'u64)
    request.ask.collateral -= 1.u256
    let item1 = SlotQueueItem.init(request, 1'u64)
    check sq.push(item0).isOk
    check sq.push(item1).isOk
    check sq[0] == item1

  test "sorts items by expiry descending (longer expiry = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0'u64)
    request.expiry += 1.u256
    let item1 = SlotQueueItem.init(request, 1'u64)
    check sq.push(item0).isOk
    check sq.push(item1).isOk
    check sq[0] == item1

  test "sorts items by slot size ascending (smaller dataset = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0'u64)
    request.ask.slotSize -= 1.u256
    let item1 = SlotQueueItem.init(request, 1'u64)
    check sq.push(item0).isOk
    check sq.push(item1).isOk
    check sq[0] == item1

  test "should call callback once an item is added":
    let item = SlotQueueItem.example
    check not onProcessSlotCalled
    check sq.push(item).isOk
    check eventually onProcessSlotCalled

  test "should only process item once":
    let item = SlotQueueItem.example

    check sq.push(item).isOk
    await sleepAsync(1.millis)
    # sq.delete(item)
    # additional sleep ensures that enough time is given for the slotqueue
    # loop to iterate again and that the correct behavior of waiting when the
    # queue is empty is adhered to
    await sleepAsync(1.millis)

    check onProcessSlotCalledWith == @[(item.requestId, item.slotIndex)]

  test "should process items in correct order":
    # sleeping after push allows the slotqueue loop to iterate,
    # calling the callback for each pushed/updated item
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0'u64)
    request.ask.reward += 1.u256
    let item1 = SlotQueueItem.init(request, 1'u64)
    request.ask.reward += 1.u256
    let item2 = SlotQueueItem.init(request, 2'u64)
    request.ask.reward += 1.u256
    let item3 = SlotQueueItem.init(request, 3'u64)
    request.ask.reward += 1.u256
    let item4 = SlotQueueItem.init(request, 4'u64)

    check sq.push(item0).isOk
    await sleepAsync(1.millis)
    check sq.push(item1).isOk
    await sleepAsync(1.millis)
    check sq.push(item2).isOk
    await sleepAsync(1.millis)
    check sq.push(item3).isOk
    await sleepAsync(1.millis)
    check sq.push(item4).isOk
    await sleepAsync(1.millis)

    check onProcessSlotCalledWith == @[(item0.requestId, item0.slotIndex),
                                       (item1.requestId, item1.slotIndex),
                                       (item2.requestId, item2.slotIndex),
                                       (item3.requestId, item3.slotIndex),
                                       (item4.requestId, item4.slotIndex)]
