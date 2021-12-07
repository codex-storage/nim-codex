## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos

type
  AsyncFutureStreamError* = CatchableError
  AsyncFuturesStreamWaitingError* = AsyncFutureStreamError
  AsyncFuturesStreamPushingError* = AsyncFutureStreamError

  AsyncFutureStream*[T] = ref object of RootObj
    q: AsyncQueue[T]
    finished: bool
    waiting: bool

  AsyncPushable*[T] = ref object of AsyncFutureStream[T]
    pushing: bool

proc finish*[T](p: AsyncFutureStream[T]) =
  p.finished = true

proc next*[T](p: AsyncFutureStream[T]): Future[T] {.async.} =
  if p.finished and p.q.len <= 0:
    raise newException(
      AsyncFuturesStreamPushingError, "Stream already ended!")

  if p.waiting:
    raise newException(
      AsyncFuturesStreamWaitingError, "This stream is already piped!")

  try:
    p.waiting = true
    return await p.q.popFirst()
  except CatchableError as exc:
    raise newException(AsyncFutureStreamError, exc.msg)
  finally:
    p.waiting = false

iterator items*[T](p: AsyncFutureStream[T]): Future[T] =
  while not p.finished:
    yield p.next()

proc new*[T](S: type AsyncFutureStream[T]): S =
  S(q: newAsyncQueue[T](1))

proc push*[T](p: AsyncPushable[T], item: T): Future[void] {.async.} =
  if p.finished:
    raise newException(
      AsyncFuturesStreamPushingError, "Stream already ended!")

  if p.pushing:
    raise newException(
      AsyncFuturesStreamPushingError, "A push is already in progress!")

  try:
    p.pushing = true
    await p.q.addLast(item)
  except CatchableError as exc:
    raise newException(AsyncFutureStreamError, exc.msg)
  finally:
    p.pushing = false

proc new*[T](S: type AsyncPushable[T]): S =
  S(q: newAsyncQueue[T](1))
