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

## Public interface:
##
## Attributes
## - next - allows to set a custom function to be called when the next item is requested
##
## Operations:
## - new - to create a new iterator (Iter)
## - finish - to finish the iterator
## - finished - to check if the iterator is finished
## - next - to get the next item from the iterator
## - items - to iterate over the iterator
## - pairs - to iterate over the iterator and return the index of each item
## - map - to convert one iterator (Iter) to another iterator (Iter)
## - mapFilter - to convert one iterator (Iter) to another iterator (Iter) and apply filtering at the same time
## - filter - to filter an iterator (Iter) and return another iterator (Iter)
## - empty - to create an empty async iterator (AsyncIter)

type
  IterFunction[T, U] = proc(value: T): U {.raises: [CatchableError], gcsafe.}
  IterIsFinished = proc(): bool {.raises: [], gcsafe.}
  IterGenNext[T] = proc(): T {.raises: [CatchableError], gcsafe.}
  Iterator[T] = iterator (): T

  Iter*[T] = ref object
    finished: bool
    next*: IterGenNext[T]

########################################################################
## Iter public interface methods
########################################################################

proc new*[T](
    _: type Iter[T],
    genNext: IterGenNext[T],
    isFinished: IterIsFinished,
    finishOnErr: bool = true,
): Iter[T] =
  ## Creates a new Iter using elements returned by supplier function `genNext`.
  ## Iter is finished whenever `isFinished` returns true.
  ##

  var iter = Iter[T]()

  proc next(): T {.raises: [CatchableError].} =
    if not iter.finished:
      var item: T
      try:
        item = genNext()
      except CatchableError as err:
        if finishOnErr or isFinished():
          iter.finish
        raise err

      if isFinished():
        iter.finish
      return item
    else:
      raise newException(CatchableError, "Iter is finished but next item was requested")

  if isFinished():
    iter.finish

  iter.next = next
  return iter

proc new*[U, V, S: Ordinal](_: type Iter[U], a: U, b: V, step: S = 1): Iter[U] =
  ## Creates a new Iter in range a..b with specified step (default 1)
  ##

  var i = a

  proc genNext(): U =
    let u = i
    inc(i, step)
    u

  proc isFinished(): bool =
    (step > 0 and i > b) or (step < 0 and i < b)

  Iter[U].new(genNext, isFinished)

proc new*[U, V: Ordinal](_: type Iter[U], slice: HSlice[U, V]): Iter[U] =
  ## Creates a new Iter from a slice
  ##

  Iter[U].new(slice.a.int, slice.b.int, 1)

proc new*[T](_: type Iter[T], items: seq[T]): Iter[T] =
  ## Creates a new Iter from a sequence
  ##

  Iter[int].new(0 ..< items.len).map((i: int) => items[i])

proc new*[T](_: type Iter[T], iter: Iterator[T]): Iter[T] =
  ## Creates a new Iter from an iterator
  ##
  var nextOrErr: Option[?!T]
  proc tryNext(): void =
    nextOrErr = none(?!T)
    while not iter.finished:
      try:
        let t: T = iter()
        if not iter.finished:
          nextOrErr = some(success(t))
        break
      except CatchableError as err:
        nextOrErr = some(T.failure(err))

  proc genNext(): T {.raises: [CatchableError].} =
    if nextOrErr.isNone:
      raise newException(CatchableError, "Iterator finished but genNext was called")

    without u =? nextOrErr.unsafeGet, err:
      raise err

    tryNext()
    return u

  proc isFinished(): bool =
    nextOrErr.isNone

  tryNext()
  Iter[T].new(genNext, isFinished)

proc finish*[T](self: Iter[T]): void =
  self.finished = true

proc finished*[T](self: Iter[T]): bool =
  self.finished

iterator items*[T](self: Iter[T]): T =
  while not self.finished:
    yield self.next()

iterator pairs*[T](self: Iter[T]): tuple[key: int, val: T] {.inline.} =
  var i = 0
  while not self.finished:
    yield (i, self.next())
    inc(i)

proc map*[T, U](iter: Iter[T], fn: IterFunction[T, U]): Iter[U] =
  Iter[U].new(genNext = () => fn(iter.next()), isFinished = () => iter.finished)

proc mapFilter*[T, U](iter: Iter[T], mapPredicate: IterFunction[T, Option[U]]): Iter[U] =
  var nextUOrErr: Option[?!U]

  proc tryFetch(): void =
    nextUOrErr = none(?!U)
    while not iter.finished:
      try:
        let t = iter.next()
        if u =? mapPredicate(t):
          nextUOrErr = some(success(u))
          break
      except CatchableError as err:
        nextUOrErr = some(U.failure(err))

  proc genNext(): U {.raises: [CatchableError].} =
    if nextUOrErr.isNone:
      raise newException(CatchableError, "Iterator finished but genNext was called")

    # at this point nextUOrErr should always be some(..)
    without u =? nextUOrErr.unsafeGet, err:
      raise err

    tryFetch()
    return u

  proc isFinished(): bool =
    nextUOrErr.isNone

  tryFetch()
  Iter[U].new(genNext, isFinished)

proc filter*[T](iter: Iter[T], predicate: IterFunction[T, bool]): Iter[T] =
  proc wrappedPredicate(t: T): Option[T] =
    if predicate(t):
      some(t)
    else:
      T.none

  mapFilter[T, T](iter, wrappedPredicate)

proc empty*[T](_: type Iter[T]): Iter[T] =
  ## Creates an empty Iter
  ##

  proc genNext(): T {.raises: [CatchableError].} =
    raise newException(CatchableError, "Next item requested from an empty Iter")

  proc isFinished(): bool =
    true

  Iter[T].new(genNext, isFinished)