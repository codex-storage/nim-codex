import pkg/chronos

import codex/utils/asyncdataevent

import ../../asynctest
import ../helpers

type
  ExampleData = object
    s: string

asyncchecksuite "AsyncDataEvent":
  var event: AsyncDataEvent[ExampleData]
  let msg = "Yeah!"

  setup:
    event = newAsyncDataEvent[ExampleData]()

  teardown:
    await event.unsubscribeAll()

  test "Successful event":
    var data = ""
    proc eventHandler(e: ExampleData): Future[?!void] {.async.} =
      data = e.s
      success()

    event.subscribe(eventHandler)

    check:
      isOK(await event.fire(ExampleData(
        s: msg
      )))
      data == msg

  test "Failed event preserves error message":
    proc eventHandler(e: ExampleData): Future[?!void] {.async.} =
      failure(msg)

    event.subscribe(eventHandler)
    let fireResult = await event.fire(ExampleData(
      s: "a"
    ))

    check:
      fireResult.isErr
      fireResult.error.msg == msg

  test "Emits data to multiple subscribers":
    var
      data1 = ""
      data2 = ""
      data3 = ""

    proc handler1(e: ExampleData): Future[?!void] {.async.} =
      data1 = e.s
      success()
    proc handler2(e: ExampleData): Future[?!void] {.async.} =
      data2 = e.s
      success()
    proc handler3(e: ExampleData): Future[?!void] {.async.} =
      data3 = e.s
      success()

    event.subscribe(handler1)
    event.subscribe(handler2)
    event.subscribe(handler3)

    let fireResult = await event.fire(ExampleData(
        s: msg
    ))

    check:
      fireResult.isOK
      data1 == msg
      data2 == msg
      data3 == msg
