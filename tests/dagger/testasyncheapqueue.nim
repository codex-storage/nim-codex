import pkg/chronos
import pkg/asynctest
import pkg/dagger/utils/asyncheapqueue

proc toSortedSeq[T](h: AsyncHeapQueue[T]): seq[T] =
  var tmp = newAsyncHeapQueue[T]()
  for d in h: tmp.pushNoWait(d)
  while tmp.len > 0:
    result.add(popNoWait(tmp))

suite "synchronous tests":
  test "test pushNoWait":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      heap.pushNoWait(item)

    check heap[0] == 0
    check heap.toSortedSeq == @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

  test "test popNoWait":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      heap.pushNoWait(item)

    var res: seq[int]
    while heap.len > 0:
      res.add(heap.popNoWait())

    check res == @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

  test "test del": # Test del
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data: heap.pushNoWait(item)

    heap.del(0)
    doAssert(heap[0] == 1)

    heap.del(heap.find(7))
    check heap.toSortedSeq == @[1, 2, 3, 4, 5, 6, 8, 9]

    heap.del(heap.find(5))
    check heap.toSortedSeq == @[1, 2, 3, 4, 6, 8, 9]

    heap.del(heap.find(6))
    check heap.toSortedSeq == @[1, 2, 3, 4, 8, 9]

    heap.del(heap.find(2))
    check heap.toSortedSeq == @[1, 3, 4, 8, 9]

  test "del last": # Test del last
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 2, 3]
    for item in data: heap.pushNoWait(item)

    heap.del(2)
    check heap.toSortedSeq == @[1, 2]

    heap.del(1)
    check heap.toSortedSeq == @[1]

    heap.del(0)
    check heap.toSortedSeq == newSeq[int]() # empty seq has no type

  test "should throw popping from an empty queue":
    var heap = newAsyncHeapQueue[int]()
    expect AsyncHeapQueueEmptyError:
      discard heap.popNoWait()

  test "should throw pushing to an empty queue":
    var heap = newAsyncHeapQueue[int](1)
    heap.pushNoWait(1)
    expect AsyncHeapQueueFullError:
      heap.pushNoWait(2)

  test "test clear":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data: heap.pushNoWait(item)

    check heap.len == 10
    heap.clear()
    check heap.len == 0

suite "asynchronous tests":

  test "test push":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      await push(heap, item)
    check heap[0] == 0
    check heap.toSortedSeq == @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

  test "test push and pop with maxSize":
    var heap = newAsyncHeapQueue[int](5)
    let data = [1, 9, 5, 3, 7, 4, 2]

    proc pushTask() {.async.} =
      for item in data:
        await push(heap, item)

    asyncCheck pushTask()

    check heap.len == 5
    check heap[0] == 1 # because we haven't pushed 0 yet

    check (await heap.pop) == 1
    check (await heap.pop) == 3
    check (await heap.pop) == 5
    check (await heap.pop) == 7
    check (await heap.pop) == 9

    await sleepAsync(1.milliseconds) # allow poll to run once more
    check (await heap.pop) == 2
    check (await heap.pop) == 4

  test "test pop":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      heap.pushNoWait(item)

    var res: seq[int]
    while heap.len > 0:
      res.add((await heap.pop()))

    check res == @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
