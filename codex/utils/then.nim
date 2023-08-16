import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/upraises

# Similar to JavaScript's Promise API, `.then` and `.catch` can be used to
# handle results and errors of async `Futures` within a synchronous closure.
# They can be used as an alternative to `asyncSpawn` which does not return a
# value and will raise a `FutureDefect` if there are unhandled errors
# encountered. Both `.then` and `.catch` act as callbacks that do not block the
# synchronous closure's flow.

# `.then` is called when the `Future` is successfully completed and can be
# chained as many times as desired, calling each `.then` callback in order. When
# the `Future` returns `Result[T, ref CatchableError]` (or `?!T`), the value
# called in the `.then` callback will be unpacked from the `Result` as a
# convenience. In other words, for `Future[?!T]`, the `.then` callback will take
# a single parameter `T`. See `tests/utils/testthen.nim` for more examples. To
# allow for chaining, `.then` returns its future. If the future is already
# complete, the `.then` callback will be executed immediately.

# `.catch` is called when the `Future` fails. In the case when the `Future`
# returns a `Result[T, ref CatchableError` (or `?!T`), `.catch` will be called
# if the `Result` contains an error. If the `Future` is already failed (or
# `Future[?!T]` contains an error), the `.catch` callback will be executed
# immediately.

# `.cancelled` is called when the `Future` is cancelled. If the `Future` is
# already cancelled, the `.cancelled` callback will be executed immediately.

# More info on JavaScript's Promise API can be found at:
# https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise

runnableExamples:
  proc asyncProc(): Future[int] {.async.} =
    await sleepAsync(1.millis)
    return 1

  asyncProc()
    .then(proc(i: int) = echo "returned ", i)
    .catch(proc(e: ref CatchableError) = doAssert false, "will not be triggered")

  # outputs "returned 1"

  proc asyncProcWithError(): Future[int] {.async.} =
    await sleepAsync(1.millis)
    raise newException(ValueError, "some error")

  asyncProcWithError()
    .then(proc(i: int) = doAssert false, "will not be triggered")
    .catch(proc(e: ref CatchableError) = echo "errored: ", e.msg)

  # outputs "errored: some error"

type
  OnSuccess*[T] = proc(val: T) {.gcsafe, upraises: [].}
  OnError* = proc(err: ref CatchableError) {.gcsafe, upraises: [].}
  OnCancelled* = proc() {.gcsafe, upraises: [].}

proc ignoreError(err: ref CatchableError) = discard
proc ignoreCancelled() = discard

template handleFinished(future: FutureBase,
                        onError: OnError,
                        onCancelled: OnCancelled) =

  if not future.finished:
    return

  if future.cancelled:
    onCancelled()
    return

  if future.failed:
    onError(future.error)
    return

proc then*(future: Future[void], onSuccess: OnSuccess[void]): Future[void] =

  proc cb(udata: pointer) =
    future.handleFinished(ignoreError, ignoreCancelled)
    onSuccess()

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc then*[T](future: Future[T], onSuccess: OnSuccess[T]): Future[T] =

  proc cb(udata: pointer) =
    future.handleFinished(ignoreError, ignoreCancelled)

    if val =? future.read.catch:
      onSuccess(val)

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc then*[T](future: Future[?!T], onSuccess: OnSuccess[T]): Future[?!T] =

  proc cb(udata: pointer) =
    future.handleFinished(ignoreError, ignoreCancelled)

    try:
      if val =? future.read:
        onSuccess(val)
    except CatchableError as e:
      ignoreError(e)

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc then*(future: Future[?!void], onSuccess: OnSuccess[void]): Future[?!void] =

  proc cb(udata: pointer) =
    future.handleFinished(ignoreError, ignoreCancelled)

    try:
      if future.read.isOk:
        onSuccess()
    except CatchableError as e:
      ignoreError(e)
      return

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc catch*[T](future: Future[T], onError: OnError) =

  if future.isNil: return

  proc cb(udata: pointer) =
    future.handleFinished(onError, ignoreCancelled)

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation

proc catch*[T](future: Future[?!T], onError: OnError) =

  if future.isNil: return

  proc cb(udata: pointer) =
    future.handleFinished(onError, ignoreCancelled)

    try:
      if err =? future.read.errorOption:
        onError(err)
    except CatchableError as e:
      onError(e)

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation

proc cancelled*[T](future: Future[T], onCancelled: OnCancelled): Future[T] =

  proc cb(udata: pointer) =
    future.handleFinished(ignoreError, onCancelled)

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)
    onCancelled()

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc cancelled*[T](future: Future[?!T], onCancelled: OnCancelled): Future[?!T] =

  proc cb(udata: pointer) =
    future.handleFinished(ignoreError, onCancelled)

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)
    onCancelled()

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future
