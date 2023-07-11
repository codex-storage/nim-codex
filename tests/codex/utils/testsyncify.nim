import pkg/asynctest
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import codex/utils/syncify
import ../helpers

asyncchecksuite "syncify":
  var returnsVoidWasRun: bool
  var returnsValWasRun: bool
  var returnsResultVoidWasRun: bool
  var returnsResultValWasRun: bool
  var error = (ref CatchableError)(msg: "some error")

  setup:
    returnsVoidWasRun = false
    returnsValWasRun = false
    returnsResultVoidWasRun = false
    returnsResultValWasRun = false


  proc returnsVoid() {.async.} =
    await sleepAsync 1.millis
    returnsVoidWasRun = true

  proc returnsVal(): Future[int] {.async.} =
    await sleepAsync 1.millis
    returnsValWasRun = true
    return 1

  proc returnsResultVoid(): Future[?!void] {.async.} =
    await sleepAsync 1.millis
    returnsResultVoidWasRun = true
    return success()

  proc returnsResultVal(): Future[?!int] {.async.} =
    await sleepAsync 1.millis
    returnsResultValWasRun = true
    return success(2)

  proc returnsVoidError() {.async.} =
    raise error

  proc returnsValError(): Future[int] {.async.} =
    raise error

  proc returnsResultVoidError(): Future[?!void] {.async.} =
    return failure(error)

  proc returnsResultValError(): Future[?!int] {.async.} =
    return failure(error)

  proc returnsVoidCancelled() {.async.} =
    await sleepAsync(1.seconds)

  proc returnsValCancelled(): Future[int] {.async.} =
    await sleepAsync(1.seconds)

  proc returnsResultVoidCancelled(): Future[?!void] {.async.} =
    await sleepAsync(1.seconds)
    return success()

  proc returnsResultValCancelled(): Future[?!int] {.async.} =
    await sleepAsync(1.seconds)
    return success(3)

  proc wasCancelled(error: ref CancelledError): bool =
    not error.isNil and error.msg == "Future operation cancelled!"

  test "calls async proc when returns Future[void]":
    syncify returnsVoid(),
      onCancelled = proc(err: ref CancelledError) = discard,
      onError = proc(err: ref CatchableError) = discard
    check eventually returnsVoidWasRun

  test "returns correct value in OnSuccess for Future[T] async proc":
    var returnedVal = 0
    syncify returnsVal(),
      onSuccess = (proc(val: int) {.upraises:[].}=
        returnedVal = val),
      onCancelled = proc(err: ref CancelledError) = discard,
      onError = proc(err: ref CatchableError) = discard
    check eventually returnsValWasRun
    check returnedVal == 1

  test "calls async proc when return Future[?!void]":
    syncify returnsResultVoid(),
      onCancelled = proc(err: ref CancelledError) = discard,
      onError = proc(err: ref CatchableError) = discard
    check eventually returnsResultVoidWasRun

  test "returns correct value in OnSuccess for Future[?!T]":
    var returnedVal = 0
    syncify returnsResultVal(),
      onSuccess = (proc(val: int) =
        returnedVal = val),
      onCancelled = proc(err: ref CancelledError) = discard,
      onError = proc(err: ref CatchableError) = discard
    check eventually returnsResultValWasRun
    check returnedVal == 2

  test "handles raised errors for async procs that return Future[void]":
    var errorRaised: ref CatchableError
    syncify returnsVoidError(),
      onCancelled = proc(err: ref CancelledError) = discard,
      onError = proc(err: ref CatchableError) =
        errorRaised = err
    check eventually errorRaised == error

  test "handles raised errors for async procs that return Future[T]":
    var errorRaised: ref CatchableError
    syncify returnsValError(),
      onSuccess = proc(val: int) {.upraises:[].} = discard,
      onCancelled = proc(err: ref CancelledError) = discard,
      onError = proc(err: ref CatchableError) =
        errorRaised = err
    check eventually errorRaised == error

  test "handles raised errors for async procs that return Future[?!void]":
    var errorRaised: ref CatchableError
    syncify returnsResultVoidError(),
      onCancelled = proc(err: ref CancelledError) = discard,
      onError = proc(err: ref CatchableError) =
        errorRaised = err
    check eventually errorRaised == error

  test "handles raised errors for async procs that return Future[?!T]":
    var errorRaised: ref CatchableError
    syncify returnsResultValError(),
      onSuccess = proc(val: int) = discard,
      onCancelled = proc(err: ref CancelledError) = discard,
      onError = proc(err: ref CatchableError) =
        errorRaised = err
    check eventually errorRaised == error

  test "handles cancelled errors for async procs that return Future[void]":
    var raised: ref CancelledError
    let run = returnsVoidCancelled()

    syncify run,
      onCancelled = (proc(err: ref CancelledError) =
        raised = err),
      onError = proc(err: ref CatchableError) = discard

    run.cancel()

    check eventually raised.wasCancelled

  test "handles cancelled errors for async procs that return Future[T]":
    var raised: ref CancelledError
    let run = returnsValCancelled()

    syncify run,
      onSuccess = proc(err: int) = discard,
      onCancelled = (proc(err: ref CancelledError) =
        raised = err),
      onError = proc(err: ref CatchableError) = discard

    run.cancel()

    check eventually raised.wasCancelled

  test "handles cancelled errors for async procs that return Future[?!void]":
    var raised: ref CancelledError
    let run = returnsResultVoidCancelled()

    syncify run,
      onCancelled = (proc(err: ref CancelledError) =
        raised = err),
      onError = proc(err: ref CatchableError) = discard

    run.cancel()

    check eventually raised.wasCancelled

  test "handles cancelled errors for async procs that return Future[?!T]":
    var raised: ref CancelledError
    let run = returnsResultValCancelled()

    syncify run,
      onSuccess = proc(err: int) = discard,
      onCancelled = (proc(err: ref CancelledError) =
        raised = err),
      onError = proc(err: ref CatchableError) = discard

    run.cancel()

    check eventually raised.wasCancelled
