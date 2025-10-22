## Nim-Codex
## Copyright (c) 2025 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sugar

import pkg/questionable
import pkg/chronos

import ./iter

## AsyncIter[T] is similar to `Iter[Future[T]]` with
## addition of methods specific to asynchronous processing.
##
## Public interface:
##
## Attributes
## - next - allows to set a custom function to be called when the next item is requested
##
## Operations:
## - new - to create a new async iterator (AsyncIter)
## - finish - to finish the async iterator
## - finished - to check if the async iterator is finished
## - next - to get the next item from the async iterator
## - items - to iterate over the async iterator
## - pairs - to iterate over the async iterator and return the index of each item
## - mapFuture - to convert a (raising) Future[T] to a (raising) Future[U] using a function fn: auto -> Future[U] - we use auto to handle both raising and non-raising futures
## - mapAsync - to convert a regular sync iterator (Iter) to an async iterator (AsyncIter)
## - map - to convert one async iterator (AsyncIter) to another async iterator (AsyncIter)
## - mapFilter - to convert one async iterator (AsyncIter) to another async iterator (AsyncIter) and apply filtering at the same time
## - filter - to filter an async iterator (AsyncIter) and return another async iterator (AsyncIter)
## - delayBy - to delay each item returned by async iterator by a given duration
## - empty - to create an empty async iterator (AsyncIter)

type
  AsyncIterFunc[T, U] = proc(fut: T): Future[U] {.async.}
  AsyncIterIsFinished = proc(): bool {.raises: [], gcsafe.}
  AsyncIterGenNext[T] = proc(): Future[T] {.async.}

  AsyncIter*[T] = ref object
    finished: bool
    next*: AsyncIterGenNext[T]

proc flatMap[T, U](fut: Future[T], fn: AsyncIterFunc[T, U]): Future[U] {.async.} =
  let t = await fut
  await fn(t)

########################################################################
## AsyncIter public interface methods
########################################################################

proc new*[T](
    _: type AsyncIter[T],
    genNext: AsyncIterGenNext[T],
    isFinished: AsyncIterIsFinished,
    finishOnErr: bool = true,
): AsyncIter[T] =
  ## Creates a new Iter using elements returned by supplier function `genNext`.
  ## Iter is finished whenever `isFinished` returns true.
  ##

  var iter = AsyncIter[T]()

  proc next(): Future[T] {.async.} =
    if not iter.finished:
      var item: T
      try:
        item = await genNext()
      except CancelledError as err:
        iter.finish
        raise err
      except CatchableError as err:
        if finishOnErr or isFinished():
          iter.finish
        raise err

      if isFinished():
        iter.finish
      return item
    else:
      raise newException(
        CatchableError, "AsyncIter is finished but next item was requested"
      )

  if isFinished():
    iter.finish

  iter.next = next
  return iter

# forward declaration
proc mapAsync*[T, U](iter: Iter[T], fn: AsyncIterFunc[T, U]): AsyncIter[U]

proc new*[U, V: Ordinal](_: type AsyncIter[U], slice: HSlice[U, V]): AsyncIter[U] =
  ## Creates new Iter from a slice
  ##

  let iter = Iter[U].new(slice)
  mapAsync[U, U](
    iter,
    proc(i: U): Future[U] {.async.} =
      i,
  )

proc new*[U, V, S: Ordinal](
    _: type AsyncIter[U], a: U, b: V, step: S = 1
): AsyncIter[U] =
  ## Creates new Iter in range a..b with specified step (default 1)
  ##

  let iter = Iter[U].new(a, b, step)
  mapAsync[U, U](
    iter,
    proc(i: U): Future[U] {.async.} =
      i,
  )

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

proc mapFuture*[T, U](fut: Future[T], fn: AsyncIterFunc[T, U]): Future[U] {.async.} =
  let t = await fut
  fn(t)

proc mapAsync*[T, U](iter: Iter[T], fn: AsyncIterFunc[T, U]): AsyncIter[U] =
  AsyncIter[U].new(genNext = () => fn(iter.next()), isFinished = () => iter.finished())

proc map*[T, U](iter: AsyncIter[T], fn: AsyncIterFunc[T, U]): AsyncIter[U] =
  AsyncIter[U].new(
    genNext = () => iter.next().flatMap(fn), isFinished = () => iter.finished
  )

proc mapFilter*[T, U](
    iter: AsyncIter[T], mapPredicate: AsyncIterFunc[T, Option[U]]
): Future[AsyncIter[U]] {.async: (raises: [CancelledError]).} =
  var nextFutU: Option[Future[U]]

  proc tryFetch(): Future[void] {.async: (raises: [CancelledError]).} =
    nextFutU = Future[U].none
    while not iter.finished:
      let futT = iter.next()
      try:
        if u =? await futT.flatMap(mapPredicate):
          let futU = newFuture[U]("AsyncIter.mapFilterAsync")
          futU.complete(u)
          nextFutU = some(futU)
          break
      except CancelledError as err:
        raise err
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
  AsyncIter[U].new(genNext, isFinished)

proc filter*[T](
    iter: AsyncIter[T], predicate: AsyncIterFunc[T, bool]
): Future[AsyncIter[T]] {.async: (raises: [CancelledError]).} =
  proc wrappedPredicate(t: T): Future[Option[T]] {.async.} =
    if await predicate(t):
      some(t)
    else:
      T.none

  await mapFilter[T, T](iter, wrappedPredicate)

proc delayBy*[T](iter: AsyncIter[T], d: Duration): AsyncIter[T] =
  ## Delays emitting each item by given duration
  ##

  map[T, T](
    iter,
    proc(t: T): Future[T] {.async.} =
      await sleepAsync(d)
      t,
  )

proc empty*[T](_: type AsyncIter[T]): AsyncIter[T] =
  ## Creates an empty AsyncIter
  ##

  proc genNext(): Future[T] {.async.} =
    raise newException(CatchableError, "Next item requested from an empty AsyncIter")

  proc isFinished(): bool =
    true

  AsyncIter[T].new(genNext, isFinished)
