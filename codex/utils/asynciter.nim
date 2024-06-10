import std/sugar

import pkg/questionable
import pkg/chronos

import ./iter

export iter

## AsyncIter[T] is similar to `Iter[Future[T]]` with addition of methods specific to asynchronous processing
##

type
  AsyncIter*[T] = ref object
    finished: bool
    next*: GenNext[Future[T]]

proc finish*[T](self: AsyncIter[T]): void =
  self.finished = true

proc finished*[T](self: AsyncIter[T]): bool =
  self.finished

iterator items*[T](self: AsyncIter[T]): Future[T] =
  while not self.finished:
    yield self.next()

iterator pairs*[T](self: AsyncIter[T]): tuple[key: int, val: Future[T]] {.inline.} =
  var i = 0
  while not self.finished:
    yield (i, self.next())
    inc(i)

proc map*[T, U](fut: Future[T], fn: Function[T, U]): Future[U] {.async.} =
  let t = await fut
  fn(t)

proc flatMap*[T, U](fut: Future[T], fn: Function[T, Future[U]]): Future[U] {.async.} =
  let t = await fut
  await fn(t)

proc newAsyncIter*[T](genNext: GenNext[Future[T]], isFinished: IsFinished, finishOnErr: bool = true): AsyncIter[T] =
  var iter = AsyncIter[T]()

  proc next(): Future[T] {.async.} =
    if not iter.finished:
      var item: T
      try:
        item = await genNext()
      except CatchableError as err:
        if finishOnErr or isFinished():
          iter.finish
        raise err

      if isFinished():
        iter.finish
      return item
    else:
      raise newException(CatchableError, "AsyncIter is finished but next item was requested")

  if isFinished():
    iter.finish

  iter.next = next
  return iter

proc emptyAsyncIter*[T](): AsyncIter[T] =
  ## Creates an empty AsyncIter
  ##

  proc genNext(): Future[T] {.raises: [CatchableError].} =
    raise newException(CatchableError, "Next item requested from an empty AsyncIter")
  proc isFinished(): bool = true

  newAsyncIter[T](genNext, isFinished)

proc map*[T, U](iter: AsyncIter[T], fn: Function[T, Future[U]]): AsyncIter[U] =
  newAsyncIter[U](
    genNext    = () => iter.next().flatMap(fn),
    isFinished = () => iter.finished
  )

proc mapFilter*[T, U](iter: AsyncIter[T], mapPredicate: Function[T, Future[Option[U]]]): Future[AsyncIter[U]] {.async.} =
  var nextFutU: Option[Future[U]]

  proc tryFetch(): Future[void] {.async.} =
    nextFutU = Future[U].none
    while not iter.finished:
      let futT = iter.next()
      try:
        if u =? await futT.flatMap(mapPredicate):
          let futU = newFuture[U]("AsyncIter.mapFilterAsync")
          futU.complete(u)
          nextFutU = some(futU)
          break
      except CatchableError as err:
        let errFut = newFuture[U]("AsyncIter.mapFilterAsync")
        errFut.fail(err)
        nextFutU = some(errFut)
        break

  proc genNext(): Future[U] {.async.} =
    let futU = nextFutU.unsafeGet
    await tryFetch()
    await futU

  proc isFinished(): bool =
    nextFutU.isNone

  await tryFetch()
  newAsyncIter[U](genNext, isFinished)

proc filter*[T](iter: AsyncIter[T], predicate: Function[T, Future[bool]]): Future[AsyncIter[T]] {.async.} =
  proc wrappedPredicate(t: T): Future[Option[T]] {.async.} =
    if await predicate(t):
      some(t)
    else:
      T.none

  await mapFilter[T, T](iter, wrappedPredicate)

proc mapAsync*[T, U](iter: Iter[T], fn: Function[T, Future[U]]): AsyncIter[U] =
  newAsyncIter[T](
    genNext = () => fn(iter.next()),
    isFinished = () => iter.finished()
  )
