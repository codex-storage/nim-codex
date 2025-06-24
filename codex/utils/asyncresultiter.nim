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
import pkg/questionable/results
import pkg/chronos

import ./iter

## AsyncResultIter[T] is similar to `AsyncIterator[Future[T]]`
## but does not throw exceptions others than CancelledError.
## 
## Instead of throwing exception, it uses Result to communicate errors (
## thus the name AsyncResultIter). 
##
## Public interface:
##
## Attributes
## - next - allows to set a custom function to be called when the next item is requested
##
## Operations:
## - new - to create a new async iterator (AsyncResultIter)
## - finish - to finish the async iterator
## - finished - to check if the async iterator is finished
## - next - to get the next item from the async iterator
## - items - to iterate over the async iterator
## - pairs - to iterate over the async iterator and return the index of each item
## - mapFuture - to convert a (raising) Future[T] to a (raising) Future[U] using a function fn: auto -> Future[U] - we use auto to handle both raising and non-raising futures
## - mapAsync - to convert a regular sync iterator (Iter) to an async iterator (AsyncResultIter)
## - map - to convert one async iterator (AsyncResultIter) to another async iterator (AsyncResultIter)
## - mapFilter - to convert one async iterator (AsyncResultIter) to another async iterator (AsyncResultIter) and apply filtering at the same time
## - filter - to filter an async iterator (AsyncResultIter) and return another async iterator (AsyncResultIter)
## - delayBy - to delay each item returned by async iterator by a given duration
## - empty - to create an empty async iterator (AsyncResultIter)

type
  AsyncResultIterFunc[T, U] =
    proc(fut: T): Future[U] {.async: (raises: [CancelledError]).}
  AsyncResultIterIsFinished = proc(): bool {.raises: [], gcsafe.}
  AsyncResultIterGenNext[T] = proc(): Future[T] {.async: (raises: [CancelledError]).}

  AsyncResultIter*[T] = ref object
    finished: bool
    next*: AsyncResultIterGenNext[?!T]

proc flatMap[T, U](
    fut: auto, fn: AsyncResultIterFunc[?!T, ?!U]
): Future[?!U] {.async: (raises: [CancelledError]).} =
  let t = await fut
  await fn(t)

proc flatMap[T, U](
    fut: auto, fn: AsyncResultIterFunc[?!T, Option[?!U]]
): Future[Option[?!U]] {.async: (raises: [CancelledError]).} =
  let t = await fut
  await fn(t)

########################################################################
## AsyncResultIter public interface methods
########################################################################

proc new*[T](
    _: type AsyncResultIter[T],
    genNext: AsyncResultIterGenNext[?!T],
    isFinished: AsyncResultIterIsFinished,
    finishOnErr: bool = true,
): AsyncResultIter[T] =
  ## Creates a new Iter using elements returned by supplier function `genNext`.
  ## Iter is finished whenever `isFinished` returns true.
  ##

  var iter = AsyncResultIter[T]()

  proc next(): Future[?!T] {.async: (raises: [CancelledError]).} =
    try:
      if not iter.finished:
        let item = await genNext()
        if finishOnErr and err =? item.errorOption:
          iter.finished = true
          return failure(err)
        if isFinished():
          iter.finished = true
        return item
      else:
        return failure("AsyncResultIter is finished but next item was requested")
    except CancelledError as err:
      iter.finished = true
      raise err

  if isFinished():
    iter.finished = true

  iter.next = next
  return iter

# forward declaration
proc mapAsync*[T, U](
  iter: Iter[T], fn: AsyncResultIterFunc[T, ?!U], finishOnErr: bool = true
): AsyncResultIter[U]

proc new*[U, V: Ordinal](
    _: type AsyncResultIter[U], slice: HSlice[U, V], finishOnErr: bool = true
): AsyncResultIter[U] =
  ## Creates new Iter from a slice
  ##

  let iter = Iter[U].new(slice)
  mapAsync[U, U](
    iter,
    proc(i: U): Future[?!U] {.async: (raises: [CancelledError]).} =
      success[U](i),
    finishOnErr = finishOnErr,
  )

proc new*[U, V, S: Ordinal](
    _: type AsyncResultIter[U], a: U, b: V, step: S = 1, finishOnErr: bool = true
): AsyncResultIter[U] =
  ## Creates new Iter in range a..b with specified step (default 1)
  ##

  let iter = Iter[U].new(a, b, step)
  mapAsync[U, U](
    iter,
    proc(i: U): Future[?!U] {.async: (raises: [CancelledError]).} =
      U.success(i),
    finishOnErr = finishOnErr,
  )

proc finish*[T](self: AsyncResultIter[T]): void =
  self.finished = true

proc finished*[T](self: AsyncResultIter[T]): bool =
  self.finished

iterator items*[T](self: AsyncResultIter[T]): auto {.inline.} =
  while not self.finished:
    yield self.next()

iterator pairs*[T](self: AsyncResultIter[T]): auto {.inline.} =
  var i = 0
  while not self.finished:
    yield (i, self.next())
    inc(i)

proc mapFuture*[T, U](
    fut: auto, fn: AsyncResultIterFunc[T, U]
): Future[U] {.async: (raises: [CancelledError]).} =
  let t = await fut
  await fn(t)

proc mapAsync*[T, U](
    iter: Iter[T], fn: AsyncResultIterFunc[T, ?!U], finishOnErr: bool = true
): AsyncResultIter[U] =
  AsyncResultIter[U].new(
    genNext = () => fn(iter.next()),
    isFinished = () => iter.finished(),
    finishOnErr = finishOnErr,
  )

proc map*[T, U](
    iter: AsyncResultIter[T],
    fn: AsyncResultIterFunc[?!T, ?!U],
    finishOnErr: bool = true,
): AsyncResultIter[U] =
  AsyncResultIter[U].new(
    genNext = () => iter.next().flatMap(fn),
    isFinished = () => iter.finished,
    finishOnErr = finishOnErr,
  )

proc mapFilter*[T, U](
    iter: AsyncResultIter[T],
    mapPredicate: AsyncResultIterFunc[?!T, Option[?!U]],
    finishOnErr: bool = true,
): Future[AsyncResultIter[U]] {.async: (raises: [CancelledError]).} =
  var nextU: Option[?!U]

  proc filter(): Future[void] {.async: (raises: [CancelledError]).} =
    nextU = none(?!U)
    while not iter.finished:
      let futT = iter.next()
      if mappedValue =? await futT.flatMap(mapPredicate):
        nextU = some(mappedValue)
        break

  proc genNext(): Future[?!U] {.async: (raises: [CancelledError]).} =
    let u = nextU.unsafeGet
    await filter()
    u

  proc isFinished(): bool =
    nextU.isNone

  await filter()
  AsyncResultIter[U].new(genNext, isFinished, finishOnErr = finishOnErr)

proc filter*[T](
    iter: AsyncResultIter[T],
    predicate: AsyncResultIterFunc[?!T, bool],
    finishOnErr: bool = true,
): Future[AsyncResultIter[T]] {.async: (raises: [CancelledError]).} =
  proc wrappedPredicate(
      t: ?!T
  ): Future[Option[?!T]] {.async: (raises: [CancelledError]).} =
    if await predicate(t):
      some(t)
    else:
      none(?!T)

  await mapFilter[T, T](iter, wrappedPredicate, finishOnErr = finishOnErr)

proc delayBy*[T](
    iter: AsyncResultIter[T], d: Duration, finishOnErr: bool = true
): AsyncResultIter[T] =
  ## Delays emitting each item by given duration
  ##

  map[T, T](
    iter,
    proc(t: ?!T): Future[?!T] {.async: (raises: [CancelledError]).} =
      await sleepAsync(d)
      return t,
    finishOnErr = finishOnErr,
  )

proc empty*[T](_: type AsyncResultIter[T]): AsyncResultIter[T] =
  ## Creates an empty AsyncResultIter
  ##

  proc genNext(): Future[?!T] {.async: (raises: [CancelledError]).} =
    T.failure("Next item requested from an empty AsyncResultIter")

  proc isFinished(): bool =
    true

  AsyncResultIter[T].new(genNext, isFinished)
