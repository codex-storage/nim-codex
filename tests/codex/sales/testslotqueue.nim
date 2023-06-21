import std/sequtils
import pkg/asynctest
import pkg/chronos
import pkg/chronicles
import pkg/codex/sales/slotqueue
import pkg/stew/byteutils # delete me
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

  proc onProcessSlot(sqi: SlotQueueItem, processing: Future[void]) {.async.} =
    try:
      await sleepAsync(1000.millis)
      # this is not illustrative of the realistic scenario as the processing
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

  test "maxWorkers cannot surpass maxSize":
    let sq2 = SlotQueue.new(maxSize = 1, maxWorkers = 2)
    sq2.onProcessSlot = onProcessSlot
    asyncSpawn sq2.start()
    let sqi1 = SlotQueueItem.example
    let sqi2 = SlotQueueItem.example
    let sqi3 = SlotQueueItem.example
    let sqi4 = SlotQueueItem.example
    check sq2.push(sqi1).isOk
    check sq2.push(sqi2).isOk
    check sq2.push(sqi3).isOk
    check sq2.push(sqi4).isOk
    check eventually sq2.activeWorkers == 1

  test "does not surpass max workers":
    let sqi1 = SlotQueueItem.example
    let sqi2 = SlotQueueItem.example
    let sqi3 = SlotQueueItem.example
    let sqi4 = SlotQueueItem.example
    check sq.push(sqi1).isOk
    check sq.push(sqi2).isOk
    check sq.push(sqi3).isOk
    check sq.push(sqi4).isOk
    check eventually sq.activeWorkers == 3

  test "discards workers once processing completed":
    proc processSlot(sqi: SlotQueueItem, processing: Future[void]) {.async.} =
      try:
        await sleepAsync(1.millis)
        processing.complete()
      except Exception:
        discard
    sq.onProcessSlot = processSlot
    let sqi1 = SlotQueueItem.example
    let sqi2 = SlotQueueItem.example
    let sqi3 = SlotQueueItem.example
    let sqi4 = SlotQueueItem.example
    check sq.push(sqi1).isOk # finishes after 1.millis
    check sq.push(sqi2).isOk # finishes after 1.millis
    check sq.push(sqi3).isOk # finishes after 1.millis
    check sq.push(sqi4).isOk
    check eventually sq.activeWorkers == 1

suite "Slot queue":

  var sq: SlotQueue
  var onProcessSlotCalled = false
  var onProcessSlotCalledWith: seq[(RequestId, uint64)]

  proc onProcessSlot(sqi: SlotQueueItem, processing: Future[void]) {.async.} =
    onProcessSlotCalled = true
    onProcessSlotCalledWith.add (sqi.requestId, sqi.slotIndex)
    processing.complete()

  setup:
    onProcessSlotCalled = false
    onProcessSlotCalledWith = @[]
    sq = SlotQueue.new(maxSize = 2)
    sq.onProcessSlot = onProcessSlot
    asyncSpawn sq.start()

  teardown:
    sq.stop()

  test "starts out empty":
    check sq.len == 0
    check $sq == "[]"

  test "expands available all possible slot indices on init":
    let request = StorageRequest.example
    let sqis = SlotQueueItem.init(request)
    check sqis.len.uint64 == request.ask.slots
    var slotIndices = toSeq(0'u64..<request.ask.slots);
    for slotIndex in 0'u64..<request.ask.slots:
      check sqis.anyIt(it == SlotQueueItem.init(request, slotIndex))
      slotIndices.delete(slotIndex)
    check slotIndices.len == 0

  test "can add items":
    let sqi1 = SlotQueueItem.example
    let sqi2 = SlotQueueItem.example
    check sq.push(sqi1).isOk
    check sq.push(sqi2).isOk
    check sq.len == 2

  test "cannot push duplicate items":
    let sqi = SlotQueueItem.example
    check sq.push(sqi).isOk
    check sq.push(sqi).error of SlotQueueItemExistsError
    check sq.len == 1

  test "can add items past max size":
    let sqi1 = SlotQueueItem.example
    let sqi2 = SlotQueueItem.example
    let sqi3 = SlotQueueItem.example
    let sqi4 = SlotQueueItem.example
    check sq.push(sqi1).isOk
    check sq.push(sqi2).isOk
    check sq.push(sqi3).isOk
    check sq.push(sqi4).isOk
    check sq.len == 2

  test "can pop the topmost item in the queue":
    let sqi = SlotQueueItem.example
    check sq.push(sqi).isOk
    without top =? await sq.pop():
      fail()
    check top == sqi

  test "pop waits for push when empty":
    sq.stop() # otherwise .pop in `start` seems to take precedent
    let sqi = SlotQueueItem.example
    proc delayPush(sqi: SlotQueueItem) {.async.} =
      await sleepAsync(2.millis)
      check sq.push(sqi).isOk
      return

    asyncSpawn sqi.delayPush
    without top =? await sq.pop():
      fail()
    check top == sqi

  test "can delete items":
    let sqi = SlotQueueItem.example
    check sq.push(sqi).isOk
    sq.delete(sqi)
    check sq.len == 0

  test "can delete item by request id and slot id":
    let sqis = SlotQueueItem.init(StorageRequest.example)
    check sq.push(sqis).isOk
    check sq.len == 2 # maxsize == 2
    sq.delete(sqis[0].requestId, sqis[0].slotIndex)
    check sq.len == 1

  test "can delete all items by request id":
    let sqis = SlotQueueItem.init(StorageRequest.example)
    check sq.push(sqis).isOk
    check sq.len == 2 # maxsize == 2
    sq.delete(sqis[0].requestId)
    check sq.len == 0

  test "can check if contains item":
    let sqi = SlotQueueItem.example
    check sq.contains(sqi) == false
    check sq.push(sqi).isOk
    check sq.contains(sqi)

  test "can get item":
    let sqi = SlotQueueItem.example
    check sq.get(sqi.requestId, sqi.slotIndex).error of SlotQueueItemNotExistsError
    check sq.push(sqi).isOk
    without item =? sq.get(sqi.requestId, sqi.slotIndex):
      fail()
    check item == sqi

  test "sorts items by profitability ascending (higher pricePerSlot = higher priority)":
    var request = StorageRequest.example
    let sqi0 = SlotQueueItem.init(request, 0'u64)
    request.ask.reward += 1.u256
    let sqi1 = SlotQueueItem.init(request, 1'u64)
    check sq.push(sqi0).isOk
    check sq.push(sqi1).isOk
    check sq[0] == sqi1

  test "sorts items by collateral ascending (less required collateral = higher priority)":
    var request = StorageRequest.example
    let sqi0 = SlotQueueItem.init(request, 0'u64)
    request.ask.collateral -= 1.u256
    let sqi1 = SlotQueueItem.init(request, 1'u64)
    check sq.push(sqi0).isOk
    check sq.push(sqi1).isOk
    check sq[0] == sqi1

  test "sorts items by expiry descending (longer expiry = higher priority)":
    var request = StorageRequest.example
    let sqi0 = SlotQueueItem.init(request, 0'u64)
    request.expiry += 1.u256
    let sqi1 = SlotQueueItem.init(request, 1'u64)
    check sq.push(sqi0).isOk
    check sq.push(sqi1).isOk
    check sq[0] == sqi1

  test "sorts items by slot size ascending (smaller dataset = higher priority)":
    var request = StorageRequest.example
    let sqi0 = SlotQueueItem.init(request, 0'u64)
    request.ask.slotSize -= 1.u256
    let sqi1 = SlotQueueItem.init(request, 1'u64)
    check sq.push(sqi0).isOk
    check sq.push(sqi1).isOk
    check sq[0] == sqi1

  test "should call callback once an item is added":
    let sqi = SlotQueueItem.example
    check not onProcessSlotCalled
    check sq.push(sqi).isOk
    check eventually onProcessSlotCalled

  test "should only process item once":
    let sqi = SlotQueueItem.example

    check sq.push(sqi).isOk
    await sleepAsync(1.millis)
    # sq.delete(sqi)
    # additional sleep ensures that enough time is given for the slotqueue
    # loop to iterate again and that the correct behavior of waiting when the
    # queue is empty is adhered to
    await sleepAsync(1.millis)

    check onProcessSlotCalledWith == @[(sqi.requestId, sqi.slotIndex)]

  test "should process items in correct order":
    # sleeping after push allows the slotqueue loop to iterate,
    # calling the callback for each pushed/updated item
    var request = StorageRequest.example
    let sqi0 = SlotQueueItem.init(request, 0'u64)
    request.ask.reward += 1.u256
    let sqi1 = SlotQueueItem.init(request, 1'u64)
    request.ask.reward += 1.u256
    let sqi2 = SlotQueueItem.init(request, 2'u64)
    request.ask.reward += 1.u256
    let sqi3 = SlotQueueItem.init(request, 3'u64)
    request.ask.reward += 1.u256
    let sqi4 = SlotQueueItem.init(request, 4'u64)

    check sq.push(sqi0).isOk
    await sleepAsync(1.millis)
    check sq.push(sqi1).isOk
    await sleepAsync(1.millis)
    check sq.push(sqi2).isOk
    await sleepAsync(1.millis)
    check sq.push(sqi3).isOk
    await sleepAsync(1.millis)
    check sq.push(sqi4).isOk
    await sleepAsync(1.millis)

    check onProcessSlotCalledWith == @[(sqi0.requestId, sqi0.slotIndex),
                                       (sqi1.requestId, sqi1.slotIndex),
                                       (sqi2.requestId, sqi2.slotIndex),
                                       (sqi3.requestId, sqi3.slotIndex),
                                       (sqi4.requestId, sqi4.slotIndex)]
