import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import codex/utils/then

import ../../asynctest
import ../helpers

proc newError(): ref CatchableError =
  (ref CatchableError)(msg: "some error")

asyncchecksuite "then - Future[void]":
  var error = newError()
  var future: Future[void]

  setup:
    future = newFuture[void]("test void")

  teardown:
    if not future.finished:
      raiseAssert "test should finish future"

  test "then callback is fired when future is already finished":
    var firedImmediately = false
    future.complete()
    discard future.then(proc() = firedImmediately = true)
    check eventually firedImmediately

  test "then callback is fired after future is finished":
    var fired = false
    discard future.then(proc() = fired = true)
    future.complete()
    check eventually fired

  test "catch callback is fired when future is already failed":
    var actual: ref CatchableError
    future.fail(error)
    future.catch(proc(err: ref CatchableError) = actual = err)
    check eventually actual == error

  test "catch callback is fired after future is failed":
    var actual: ref CatchableError
    future.catch(proc(err: ref CatchableError) = actual = err)
    future.fail(error)
    check eventually actual == error

  test "cancelled callback is fired when future is already cancelled":
    var fired = false
    await future.cancelAndWait()
    discard future.cancelled(proc() = fired = true)
    check eventually fired

  test "cancelled callback is fired after future is cancelled":
    var fired = false
    discard future.cancelled(proc() = fired = true)
    await future.cancelAndWait()
    check eventually fired

  test "does not fire other callbacks when successful":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc() = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    future.complete()

    check eventually onSuccessCalled
    check always (not onCancelledCalled and not onCatchCalled)

  test "does not fire other callbacks when fails":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc() = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    future.fail(error)

    check eventually onCatchCalled
    check always (not onCancelledCalled and not onSuccessCalled)

  test "does not fire other callbacks when cancelled":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc() = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    await future.cancelAndWait()

    check eventually onCancelledCalled
    check always (not onSuccessCalled and not onCatchCalled)

  test "can chain onSuccess when future completes":
    var onSuccessCalledTimes = 0
    discard future
      .then(proc() = inc onSuccessCalledTimes)
      .then(proc() = inc onSuccessCalledTimes)
      .then(proc() = inc onSuccessCalledTimes)
    future.complete()
    check eventually onSuccessCalledTimes == 3

asyncchecksuite "then - Future[T]":
  var error = newError()
  var future: Future[int]

  setup:
    future = newFuture[int]("test void")

  teardown:
    if not future.finished:
      raiseAssert "test should finish future"

  test "then callback is fired when future is already finished":
    var cbVal = 0
    future.complete(1)
    discard future.then(proc(val: int) = cbVal = val)
    check eventually cbVal == 1

  test "then callback is fired after future is finished":
    var cbVal = 0
    discard future.then(proc(val: int) = cbVal = val)
    future.complete(1)
    check eventually cbVal == 1

  test "catch callback is fired when future is already failed":
    var actual: ref CatchableError
    future.fail(error)
    future.catch(proc(err: ref CatchableError) = actual = err)
    check eventually actual == error

  test "catch callback is fired after future is failed":
    var actual: ref CatchableError
    future.catch(proc(err: ref CatchableError) = actual = err)
    future.fail(error)
    check eventually actual == error

  test "cancelled callback is fired when future is already cancelled":
    var fired = false
    await future.cancelAndWait()
    discard future.cancelled(proc() = fired = true)
    check eventually fired

  test "cancelled callback is fired after future is cancelled":
    var fired = false
    discard future.cancelled(proc() = fired = true)
    await future.cancelAndWait()
    check eventually fired

  test "does not fire other callbacks when successful":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc(val: int) = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    future.complete(1)

    check eventually onSuccessCalled
    check always (not onCancelledCalled and not onCatchCalled)

  test "does not fire other callbacks when fails":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc(val: int) = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    future.fail(error)

    check eventually onCatchCalled
    check always (not onCancelledCalled and not onSuccessCalled)

  test "does not fire other callbacks when cancelled":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc(val: int) = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    await future.cancelAndWait()

    check eventually onCancelledCalled
    check always (not onSuccessCalled and not onCatchCalled)

  test "can chain onSuccess when future completes":
    var onSuccessCalledTimes = 0
    discard future
      .then(proc(val: int) = inc onSuccessCalledTimes)
      .then(proc(val: int) = inc onSuccessCalledTimes)
      .then(proc(val: int) = inc onSuccessCalledTimes)
    future.complete(1)
    check eventually onSuccessCalledTimes == 3

asyncchecksuite "then - Future[?!void]":
  var error = newError()
  var future: Future[?!void]

  setup:
    future = newFuture[?!void]("test void")

  teardown:
    if not future.finished:
      raiseAssert "test should finish future"

  test "then callback is fired when future is already finished":
    var firedImmediately = false
    future.complete(success())
    discard future.then(proc() = firedImmediately = true)
    check eventually firedImmediately

  test "then callback is fired after future is finished":
    var fired = false
    discard future.then(proc() = fired = true)
    future.complete(success())
    check eventually fired

  test "catch callback is fired when future is already failed":
    var actual: ref CatchableError
    future.fail(error)
    future.catch(proc(err: ref CatchableError) = actual = err)
    check eventually actual == error

  test "catch callback is fired after future is failed":
    var actual: ref CatchableError
    future.catch(proc(err: ref CatchableError) = actual = err)
    future.fail(error)
    check eventually actual == error

  test "cancelled callback is fired when future is already cancelled":
    var fired = false
    await future.cancelAndWait()
    discard future.cancelled(proc() = fired = true)
    check eventually fired

  test "cancelled callback is fired after future is cancelled":
    var fired = false
    discard future.cancelled(proc() = fired = true)
    await future.cancelAndWait()
    check eventually fired

  test "does not fire other callbacks when successful":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc() = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    future.complete(success())

    check eventually onSuccessCalled
    check always (not onCancelledCalled and not onCatchCalled)

  test "does not fire other callbacks when fails":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc() = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    future.fail(error)

    check eventually onCatchCalled
    check always (not onCancelledCalled and not onSuccessCalled)

  test "does not fire other callbacks when cancelled":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc() = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    await future.cancelAndWait()

    check eventually onCancelledCalled
    check always (not onSuccessCalled and not onCatchCalled)

  test "can chain onSuccess when future completes":
    var onSuccessCalledTimes = 0
    discard future
      .then(proc() = inc onSuccessCalledTimes)
      .then(proc() = inc onSuccessCalledTimes)
      .then(proc() = inc onSuccessCalledTimes)
    future.complete(success())
    check eventually onSuccessCalledTimes == 3

asyncchecksuite "then - Future[?!T]":
  var error = newError()
  var future: Future[?!int]

  setup:
    future = newFuture[?!int]("test void")

  teardown:
    if not future.finished:
      raiseAssert "test should finish future"

  test "then callback is fired when future is already finished":
    var cbVal = 0
    future.complete(success(1))
    discard future.then(proc(val: int) = cbVal = val)
    check eventually cbVal == 1

  test "then callback is fired after future is finished":
    var cbVal = 0
    discard future.then(proc(val: int) = cbVal = val)
    future.complete(success(1))
    check eventually cbVal == 1

  test "catch callback is fired when future is already failed":
    var actual: ref CatchableError
    future.fail(error)
    future.catch(proc(err: ref CatchableError) = actual = err)
    check eventually actual == error

  test "catch callback is fired after future is failed":
    var actual: ref CatchableError
    future.catch(proc(err: ref CatchableError) = actual = err)
    future.fail(error)
    check eventually actual == error

  test "cancelled callback is fired when future is already cancelled":
    var fired = false
    await future.cancelAndWait()
    discard future.cancelled(proc() = fired = true)
    check eventually fired

  test "cancelled callback is fired after future is cancelled":
    var fired = false
    discard future.cancelled(proc() = fired = true)
    await future.cancelAndWait()
    check eventually fired

  test "does not fire other callbacks when successful":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc(val: int) = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    future.complete(success(1))

    check eventually onSuccessCalled
    check always (not onCancelledCalled and not onCatchCalled)

  test "does not fire other callbacks when fails":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc(val: int) = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    future.fail(error)

    check eventually onCatchCalled
    check always (not onCancelledCalled and not onSuccessCalled)

  test "does not fire other callbacks when cancelled":
    var onSuccessCalled = false
    var onCancelledCalled = false
    var onCatchCalled = false

    future
      .then(proc(val: int) = onSuccessCalled = true)
      .cancelled(proc() = onCancelledCalled = true)
      .catch(proc(e: ref CatchableError) = onCatchCalled = true)

    await future.cancelAndWait()

    check eventually onCancelledCalled
    check always (not onSuccessCalled and not onCatchCalled)

  test "can chain onSuccess when future completes":
    var onSuccessCalledTimes = 0
    discard future
      .then(proc(val: int) = inc onSuccessCalledTimes)
      .then(proc(val: int) = inc onSuccessCalledTimes)
      .then(proc(val: int) = inc onSuccessCalledTimes)
    future.complete(success(1))
    check eventually onSuccessCalledTimes == 3
