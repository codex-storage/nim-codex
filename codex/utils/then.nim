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
# `Future[?!T]` contains an error), the `.catch` callback will be excuted
# immediately.

# NOTE: Cancelled `Futures` are discarded as bubbling the `CancelledError` to
# the synchronous closure will likely cause an unintended and unhandled
# exception.

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
  OnFinally* = proc(): void {.gcsafe, upraises: [].}

proc ignoreError(err: ref CatchableError) = discard
proc ignoreFinally() = discard

template returnOrError(future: FutureBase, onError: OnError) =
  if not future.finished:
    return

  if future.cancelled:
    # do not bubble as closure is synchronous
    return

  if future.failed:
    onError(future.error)
    return


proc then*(future: Future[void],
           onError: OnError):
          Future[void] =

  proc cb(udata: pointer) =
    future.returnOrError(onError)

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc then*(future: Future[void],
           onSuccess: OnSuccess[void],
           onError: OnError = ignoreError,
           onFinally: OnFinally = ignoreFinally):
          Future[void] =

  proc cb(udata: pointer) =
    future.returnOrError(onError)
    onSuccess()
    onFinally()

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc then*[T](future: Future[T],
              onSuccess: OnSuccess[T],
              onError: OnError = ignoreError,
              onFinally: OnFinally = ignoreFinally):
             Future[T] =

  proc cb(udata: pointer) =
    future.returnOrError(onError)

    without val =? future.read.catch, err:
      onError(err)
      return
    onSuccess(val)
    onFinally()

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc then*[T](future: Future[?!T],
              onSuccess: OnSuccess[T],
              onError: OnError = ignoreError,
              onFinally: OnFinally = ignoreFinally):
             Future[?!T] =

  proc cb(udata: pointer) =
    future.returnOrError(onError)

    try:
      without val =? future.read, err:
        onError(err)
        return
      onSuccess(val)
      onFinally()
    except CatchableError as e:
      onError(e)

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc then*(future: Future[?!void],
           onError: OnError = ignoreError):
          Future[?!void] =

  proc cb(udata: pointer) =
    future.returnOrError(onError)

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
  return future

proc then*(future: Future[?!void],
           onSuccess: OnSuccess[void],
           onError: OnError = ignoreError,
           onFinally: OnFinally = ignoreFinally):
          Future[?!void] =

  proc cb(udata: pointer) =
    future.returnOrError(onError)

    try:
      if err =? future.read.errorOption:
        onError(err)
        return
    except CatchableError as e:
      onError(e)
      return
    onSuccess()
    onFinally()

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc catch*[T](future: Future[T], onError: OnError): Future[T] =

  proc cb(udata: pointer) =
    future.returnOrError(onError)

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
  return future

proc catch*[T](future: Future[?!T], onError: OnError): Future[?!T] =

  proc cb(udata: pointer) =
    future.returnOrError(onError)

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
  return future

proc `finally`*[T](future: Future[T], onFinally: OnFinally) =

  proc cb(udata: pointer) =
    if future.finished:
      onFinally()

  proc cancellation(udata: pointer) =
    if not future.finished():
      future.removeCallback(cb)

  future.addCallback(cb)
  future.cancelCallback = cancellation
