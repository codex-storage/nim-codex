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
  var onRequestAvailableCalled = false

  proc onRequestAvailable(rqi: RequestQueueItem) =
    echo "[test] callback called"
    onRequestAvailableCalled = true

  setup:
    market = MockMarket.new()
    rq = RequestQueue.new(onRequestAvailable)

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
  var onRequestAvailableCalled = false
  var onRequestAvailableCalledWith: seq[RequestId]

  proc onRequestAvailable(rqi: RequestQueueItem) =
    echo "[test] callback called, rqi.requestId: ", rqi.requestId
    onRequestAvailableCalled = true
    onRequestAvailableCalledWith.add rqi.requestId

  setup:
    onRequestAvailableCalled = false
    onRequestAvailableCalledWith = @[]
    market = MockMarket.new()
    rq = RequestQueue.new(onRequestAvailable, 2)
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
    copy.collateral = 1.u256
    rq.pushOrUpdate(copy)
    without top =? await rq.peek():
      fail()
    check top.collateral == copy.collateral

  test "can delete items":
    let rqi = RequestQueueItem.init(StorageRequest.example)
    rq.pushOrUpdate(rqi)
    rq.delete(rqi)
    check rq.len == 0

  test "sorts items by collateral ascending (less required collateral = higher priority)":
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.collateral = rqi1.collateral - 1
    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    without top =? await rq.peek():
      fail()
    check top.collateral == rqi2.collateral

  test "sorts items by expiry descending (longer expiry = higher priority)":
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.expiry = rqi1.expiry + 1
    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    without top =? await rq.peek():
      fail()
    check top.expiry == rqi2.expiry

  test "sorts items by total chunks ascending (smaller dataset = higher priority)":
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.totalChunks = rqi1.totalChunks - 1
    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    without top =? await rq.peek():
      fail()
    check top.totalChunks == rqi2.totalChunks

  test "should call callback once an item is added":
    let rqi = RequestQueueItem.init(StorageRequest.example)
    check not onRequestAvailableCalled
    rq.pushOrUpdate(rqi)
    check eventually onRequestAvailableCalled

  test "should only process item once":
    let rqi = RequestQueueItem.init(StorageRequest.example)

    rq.pushOrUpdate(rqi)
    await sleepAsync(1.millis)
    rq.delete(rqi)
    # additional sleep ensures that enough time is given for the requestqueue
    # loop to iterate again and that the correct behavior of waiting when the
    # queue is empty is adhered to
    await sleepAsync(1.millis)

    check onRequestAvailableCalledWith == @[rqi.requestId]

  test "should process items in correct order":
    # sleeping after pushOrUpdate allows the requestqueue loop to iterate,
    # calling the callback for each pushed/updated item
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.collateral = rqi1.collateral - 1
    var rqi3 = RequestQueueItem.init(StorageRequest.example)
    rqi3.collateral = rqi2.collateral - 1
    var rqi4 = RequestQueueItem.init(StorageRequest.example)
    rqi4.collateral = rqi3.collateral - 1
    var rqi5 = RequestQueueItem.init(StorageRequest.example)
    rqi5.collateral = rqi4.collateral - 1

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

    check onRequestAvailableCalledWith == @[rqi1.requestId, rqi2.requestId, rqi3.requestId, rqi4.requestId, rqi5.requestId]

  test "should call only highest priority item continually":
    # not sleeping after pushOrUpdate means the requestqueue loop will only
    # continue to run after all the pushOrUpdates have been called, at which
    # point the highest priority item should continually get processed (when the
    # test sleeps at the end)
    let rqi1 = RequestQueueItem.init(StorageRequest.example)
    var rqi2 = RequestQueueItem.init(StorageRequest.example)
    rqi2.collateral = rqi1.collateral - 1
    var rqi3 = RequestQueueItem.init(StorageRequest.example)
    rqi3.collateral = rqi2.collateral - 1
    var rqi4 = RequestQueueItem.init(StorageRequest.example)
    rqi4.collateral = rqi3.collateral - 1
    var rqi5 = RequestQueueItem.init(StorageRequest.example)
    rqi5.collateral = rqi4.collateral - 1

    rq.pushOrUpdate(rqi1)
    rq.pushOrUpdate(rqi2)
    rq.pushOrUpdate(rqi3)
    rq.pushOrUpdate(rqi4)
    rq.pushOrUpdate(rqi5)
    await sleepAsync(3.millis)

    check onRequestAvailableCalledWith.allIt(it == rqi5.requestId)
