import std/sequtils
import pkg/asynctest
import pkg/chronos
import pkg/codex/sales/requestqueue
import pkg/stew/byteutils # delete me
import pkg/questionable
import pkg/questionable/results
import ../helpers/mockmarket
import ../helpers/eventually
import ../examples

suite "Request queue start/stop":

  var rq: RequestQueue
  var market: MockMarket
  var onProcessRequestCalled = false

  setup:
    market = MockMarket.new()
    rq = RequestQueue.new()

  teardown:
    rq.stop()

  test "starts out not running":
    check not rq.running

  test "can call start multiple times, and when already running":
    asyncSpawn rq.start()
    asyncSpawn rq.start()
    check rq.running

  test "can call stop when alrady stopped":
    rq.stop()
    check not rq.running

  test "can call stop when running":
    asyncSpawn rq.start()
    rq.stop()
    check not rq.running

  test "can call stop multiple times":
    asyncSpawn rq.start()
    rq.stop()
    rq.stop()
    check not rq.running

suite "Request queue":

  var rq: RequestQueue
  var market: MockMarket
  var onProcessRequestCalled = false
  var onProcessRequestCalledWith: seq[RequestId]

  proc onProcessRequest(rqi: RequestQueueItem) =
    onProcessRequestCalled = true
    onProcessRequestCalledWith.add rqi.requestId

  setup:
    onProcessRequestCalled = false
    onProcessRequestCalledWith = @[]
    market = MockMarket.new()
    rq = RequestQueue.new(maxSize = 2)
    rq.onProcessRequest = onProcessRequest
    asyncSpawn rq.start()

  teardown:
    rq.stop()

  test "starts out empty":
    check rq.len == 0
    check $rq == "[]"

  test "can add items":
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    let rqi2 = RequestQueueItem.init(StorageRequest.example)
    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    check rq.len == 2

  test "can add items past max size":
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    let rqi2 = RequestQueueItem.init(StorageRequest.example)
    let rqi3 = RequestQueueItem.init(StorageRequest.example)
    let rqi4 = RequestQueueItem.init(StorageRequest.example)
    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    rq.pushOrUpdate(rqi3)
    rq.pushOrUpdate(rqi4)
    check rq.len == 2

  test "can peek the topmost item in the queue":
    let rqi = RequestQueueItem.init(StorageRequest.example)
    rq.pushOrUpdate(rqi)
    without top =? await rq.peek():
      fail()
    check top == rqi

  test "can update items":
    let rqi = RequestQueueItem.init(StorageRequest.example)
    rq.pushOrUpdate(rqi)
    var copy = rqi
    copy.ask.reward = 1.u256
    rq.pushOrUpdate(copy)
    without top =? await rq.peek():
      fail()
    check top.ask.reward == copy.ask.reward

  test "can delete items":
    let rqi = RequestQueueItem.init(StorageRequest.example)
    rq.pushOrUpdate(rqi)
    rq.delete(rqi)
    check rq.len == 0

  test "sorts items by profitability ascending (higher pricePerSlot = higher priority)":
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.ask.reward = rqi1.ask.reward + 1
    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    without top =? await rq.peek():
      fail()
    check top.ask.reward == rqi2.ask.reward

  test "sorts items by collateral ascending (less required collateral = higher priority)":
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.ask.collateral = rqi1.ask.collateral - 1
    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    without top =? await rq.peek():
      fail()
    check top.ask.collateral == rqi2.ask.collateral

  test "sorts items by expiry descending (longer expiry = higher priority)":
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.expiry = rqi1.expiry + 1
    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    without top =? await rq.peek():
      fail()
    check top.expiry == rqi2.expiry

  test "sorts items by slot size ascending (smaller dataset = higher priority)":
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.ask.slotSize = rqi1.ask.slotSize - 1
    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    without top =? await rq.peek():
      fail()
    check top.ask.slotSize == rqi2.ask.slotSize

  test "should call callback once an item is added":
    let rqi = RequestQueueItem.init(StorageRequest.example)
    check not onProcessRequestCalled
    rq.pushOrUpdate(rqi)
    check eventually onProcessRequestCalled

  test "should only process item once":
    let rqi = RequestQueueItem.init(StorageRequest.example)

    rq.pushOrUpdate(rqi)
    await sleepAsync(1.millis)
    rq.delete(rqi)
    # additional sleep ensures that enough time is given for the requestqueue
    # loop to iterate again and that the correct behavior of waiting when the
    # queue is empty is adhered to
    await sleepAsync(1.millis)

    check onProcessRequestCalledWith == @[rqi.requestId]

  test "should process items in correct order":
    # sleeping after pushOrUpdate allows the requestqueue loop to iterate,
    # calling the callback for each pushed/updated item
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.ask.reward = rqi1.ask.reward + 1
    var rqi3 = RequestQueueItem.init(StorageRequest.example)
    rqi3.ask.reward = rqi2.ask.reward + 1
    var rqi4 = RequestQueueItem.init(StorageRequest.example)
    rqi4.ask.reward = rqi3.ask.reward + 1
    var rqi5 = RequestQueueItem.init(StorageRequest.example)
    rqi5.ask.reward = rqi4.ask.reward + 1

    rq.pushOrUpdate(rqi1)
    await sleepAsync(1.millis)
    rq.pushOrUpdate(rqi2)
    await sleepAsync(1.millis)
    rq.pushOrUpdate(rqi3)
    await sleepAsync(1.millis)
    rq.pushOrUpdate(rqi4)
    await sleepAsync(1.millis)
    rq.pushOrUpdate(rqi5)
    await sleepAsync(1.millis)

    check onProcessRequestCalledWith == @[rqi1.requestId, rqi2.requestId, rqi3.requestId, rqi4.requestId, rqi5.requestId]

  test "should call only highest priority item continually":
    # not sleeping after pushOrUpdate means the requestqueue loop will only
    # continue to run after all the pushOrUpdates have been called, at which
    # point the highest priority item should continually get processed (when the
    # test sleeps at the end)
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.ask.reward = rqi1.ask.reward + 1
    var rqi3 = RequestQueueItem.init(StorageRequest.example)
    rqi3.ask.reward = rqi2.ask.reward + 1
    var rqi4 = RequestQueueItem.init(StorageRequest.example)
    rqi4.ask.reward = rqi3.ask.reward + 1
    var rqi5 = RequestQueueItem.init(StorageRequest.example)
    rqi5.ask.reward = rqi4.ask.reward + 1

    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    rq.pushOrUpdate(rqi3)
    rq.pushOrUpdate(rqi4)
    rq.pushOrUpdate(rqi5)
    await sleepAsync(3.millis)

    check onProcessRequestCalledWith.allIt(it == rqi5.requestId)
