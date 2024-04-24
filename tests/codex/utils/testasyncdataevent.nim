import pkg/chronos

import codex/utils/asyncdataevent

import ../../asynctest
import ../helpers

asyncchecksuite "AsyncDataEvent":
  test "Successful event":
    let event = newAsyncDataEvent[int]()

    var data = 0
    proc eventHandler(d: int): Future[?!void] {.async.} =
      data = d
      success()

    let handle = event.subscribeA(eventHandler)

    check:
      isOK(await event.fireA(123))
      data == 123

    await event.unsubscribeA(handle)

  test "Failed event preserves error message":
    let
      event = newAsyncDataEvent[int]()
      msg = "Error message!"

    proc eventHandler(d: int): Future[?!void] {.async.} =
      failure(msg)

    let handle = event.subscribeA(eventHandler)
    let fireResult = await event.fireA(123)

    check:
      fireResult.isErr
      fireResult.error.msg == msg

    await event.unsubscribeA(handle)