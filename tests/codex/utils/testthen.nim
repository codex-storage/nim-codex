import pkg/asynctest
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import codex/utils/then
import ../helpers

asyncchecksuite "then - Future[void]":
  var returnsVoidWasRun: bool
  var error = (ref CatchableError)(msg: "some error")

  setup:
    returnsVoidWasRun = false

  proc returnsVoid() {.async.} =
    await sleepAsync 1.millis
    returnsVoidWasRun = true

  proc returnsVoidError() {.async.} =
    raise error

  proc returnsVoidCancelled() {.async.} =
    await sleepAsync(1.seconds)

  proc wasCancelled(error: ref CancelledError): bool =
    not error.isNil and error.msg == "Future operation cancelled!"

  test "calls async proc when returns Future[void]":
    discard returnsVoid().then(
      proc(err: ref CatchableError) = discard
    )
    check eventually returnsVoidWasRun

  test "calls onSuccess when Future[void] complete":
    var onSuccessCalled = false
    discard returnsVoid().then(
      proc() = onSuccessCalled = true,
      proc(err: ref CatchableError) = discard
    )
    check eventually returnsVoidWasRun
    check eventually onSuccessCalled

  test "can pass only onSuccess for Future[void]":
    var onSuccessCalled = false
    discard returnsVoid().then(
      proc() = onSuccessCalled = true
    )
    check eventually returnsVoidWasRun
    check eventually onSuccessCalled

  test "can chain onSuccess when Future[void] complete":
    var onSuccessCalledTimes = 0
    discard returnsVoid()
      .then(proc() = inc onSuccessCalledTimes)
      .then(proc() = inc onSuccessCalledTimes)
      .then(proc() = inc onSuccessCalledTimes)
    check eventually onSuccessCalledTimes == 3

  test "calls onError when Future[void] fails":
    var errorActual: ref CatchableError
    discard returnsVoidError().then(
      proc() = discard,
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "calls onError when Future[void] fails":
    var errorActual: ref CatchableError
    discard returnsVoidError().then(
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "catch callback fired when Future[void] fails":
    var errorActual: ref CatchableError
    returnsVoidError().catch(
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "does not fire onSuccess callback when Future[void] fails":
    var onSuccessCalled = false

    returnsVoidError()
      .then(proc() = onSuccessCalled = true)
      .then(proc() = onSuccessCalled = true)
      .catch(proc(e: ref CatchableError) = discard)

    check always (not onSuccessCalled)

asyncchecksuite "then - Future[T]":
  var returnsValWasRun: bool
  var error = (ref CatchableError)(msg: "some error")

  setup:
    returnsValWasRun = false

  proc returnsVal(): Future[int] {.async.} =
    await sleepAsync 1.millis
    returnsValWasRun = true
    return 1

  proc returnsValError(): Future[int] {.async.} =
    raise error

  proc returnsValCancelled(): Future[int] {.async.} =
    await sleepAsync(1.seconds)

  proc wasCancelled(error: ref CancelledError): bool =
    not error.isNil and error.msg == "Future operation cancelled!"

  test "calls onSuccess when Future[T] complete":
    var returnedVal = 0
    discard returnsVal().then(
      proc(val: int) = returnedVal = val,
      proc(err: ref CatchableError) = discard
    )
    check eventually returnsValWasRun
    check eventually returnedVal == 1

  test "can pass only onSuccess for Future[T]":
    var returnedVal = 0
    discard returnsVal().then(
      proc(val: int) = returnedVal = val
    )
    check eventually returnsValWasRun
    check eventually returnedVal == 1

  test "can chain onSuccess when Future[T] complete":
    var onSuccessCalledWith: seq[int] = @[]
    discard returnsVal()
      .then(proc(val: int) = onSuccessCalledWith.add(val))
      .then(proc(val: int) = onSuccessCalledWith.add(val))
      .then(proc(val: int) = onSuccessCalledWith.add(val))
    check eventually onSuccessCalledWith == @[1, 1, 1]

  test "calls onError when Future[T] fails":
    var errorActual: ref CatchableError
    discard returnsValError().then(
      proc(val: int) = discard,
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "catch callback fired when Future[T] fails":
    var errorActual: ref CatchableError
    returnsValError().catch(
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "does not fire onSuccess callback when Future[T] fails":
    var onSuccessCalled = false

    returnsValError()
      .then(proc(val: int) = onSuccessCalled = true)
      .then(proc(val: int) = onSuccessCalled = true)
      .catch(proc(e: ref CatchableError) = discard)

    check always (not onSuccessCalled)

asyncchecksuite "then - Future[?!void]":
  var returnsResultVoidWasRun: bool
  var error = (ref CatchableError)(msg: "some error")

  setup:
    returnsResultVoidWasRun = false

  proc returnsResultVoid(): Future[?!void] {.async.} =
    await sleepAsync 1.millis
    returnsResultVoidWasRun = true
    return success()

  proc returnsResultVoidError(): Future[?!void] {.async.} =
    return failure(error)


  proc returnsResultVoidErrorUncaught(): Future[?!void] {.async.} =
    raise error

  proc returnsResultVoidCancelled(): Future[?!void] {.async.} =
    await sleepAsync(1.seconds)
    return success()

  proc wasCancelled(error: ref CancelledError): bool =
    not error.isNil and error.msg == "Future operation cancelled!"

  test "calls onSuccess when Future[?!void] complete":
    var onSuccessCalled = false
    discard returnsResultVoid().then(
      proc() = onSuccessCalled = true,
      proc(err: ref CatchableError) = discard
    )
    check eventually returnsResultVoidWasRun
    check eventually onSuccessCalled

  test "can pass only onSuccess for Future[?!void]":
    var onSuccessCalled = false
    discard returnsResultVoid().then(
      proc() = onSuccessCalled = true
    )
    check eventually returnsResultVoidWasRun
    check eventually onSuccessCalled

  test "can chain onSuccess when Future[?!void] complete":
    var onSuccessCalledTimes = 0
    discard returnsResultVoid()
      .then(proc() = inc onSuccessCalledTimes)
      .then(proc() = inc onSuccessCalledTimes)
      .then(proc() = inc onSuccessCalledTimes)
    check eventually onSuccessCalledTimes == 3

  test "calls onError when Future[?!void] fails":
    var errorActual: ref CatchableError
    discard returnsResultVoidError().then(
      proc() = discard,
      proc(e: ref CatchableError) = errorActual = e
    )
    await sleepAsync(10.millis)
    check eventually error == errorActual

  test "calls onError when Future[?!void] fails":
    var errorActual: ref CatchableError
    discard returnsResultVoidError().then(
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "catch callback fired when Future[?!void] fails":
    var errorActual: ref CatchableError
    returnsResultVoidError().catch(
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "does not fire onSuccess callback when Future[?!void] fails":
    var onSuccessCalled = false

    returnsResultVoidError()
      .then(proc() = onSuccessCalled = true)
      .then(proc() = onSuccessCalled = true)
      .catch(proc(e: ref CatchableError) = discard)

    check always (not onSuccessCalled)

  test "catch callback fired when Future[?!void] fails with uncaught error":
    var errorActual: ref CatchableError
    returnsResultVoidErrorUncaught().catch(
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

asyncchecksuite "then - Future[?!T]":
  var returnsResultValWasRun: bool
  var error = (ref CatchableError)(msg: "some error")

  setup:
    returnsResultValWasRun = false

  proc returnsResultVal(): Future[?!int] {.async.} =
    await sleepAsync 1.millis
    returnsResultValWasRun = true
    return success(2)

  proc returnsResultValError(): Future[?!int] {.async.} =
    return failure(error)

  proc returnsResultValErrorUncaught(): Future[?!int] {.async.} =
    raise error

  proc returnsResultValCancelled(): Future[?!int] {.async.} =
    await sleepAsync(1.seconds)
    return success(3)

  proc wasCancelled(error: ref CancelledError): bool =
    not error.isNil and error.msg == "Future operation cancelled!"

  test "calls onSuccess when Future[?!T] completes":
    var actualVal = 0
    discard returnsResultVal().then(
      proc(val: int) = actualVal = val,
      proc(err: ref CatchableError) = discard
    )
    check eventually returnsResultValWasRun
    check eventually actualVal == 2

  test "can pass only onSuccess for Future[?!T]":
    var actualVal = 0
    discard returnsResultVal().then(
      proc(val: int) = actualVal = val
    )
    check eventually returnsResultValWasRun
    check eventually actualVal == 2

  test "can chain onSuccess when Future[?!T] complete":
    var onSuccessCalledWith: seq[int] = @[]
    discard returnsResultVal()
      .then(proc(val: int) = onSuccessCalledWith.add val)
      .then(proc(val: int) = onSuccessCalledWith.add val)
      .then(proc(val: int) = onSuccessCalledWith.add val)
    check eventually onSuccessCalledWith == @[2, 2, 2]

  test "calls onError when Future[?!T] fails":
    var errorActual: ref CatchableError
    discard returnsResultValError().then(
      proc(val: int) = discard,
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "calls onError when Future[?!T] fails":
    var errorActual: ref CatchableError
    discard returnsResultValError().then(
      proc(val: int) = discard,
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "catch callback fired when Future[?!T] fails":
    var errorActual: ref CatchableError
    returnsResultValError().catch(
      proc(e: ref CatchableError) = errorActual = e
    )
    check eventually error == errorActual

  test "does not fire onSuccess callback when Future[?!T] fails":
    var onSuccessCalled = false

    returnsResultValError()
      .then(proc(val: int) = onSuccessCalled = true)
      .then(proc(val: int) = onSuccessCalled = true)
      .catch(proc(e: ref CatchableError) = discard)

    check always (not onSuccessCalled)

  test "catch callback fired when Future[?!T] fails with uncaught error":
    var errorActual: ref CatchableError

    returnsResultValErrorUncaught()
      .then(proc(val: int) = discard)
      .then(proc(val: int) = discard)
      .catch(proc(e: ref CatchableError) = errorActual = e)

    check eventually error == errorActual
