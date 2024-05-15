import std/sugar

import pkg/questionable

type
  Function*[T, U] = proc(fut: T): U {.raises: [CatchableError], gcsafe, closure.}
  IsFinished* = proc(): bool {.raises: [], gcsafe, closure.}
  GenNext*[T] = proc(): T {.raises: [CatchableError], gcsafe.}
  Iter*[T] = ref object
    finished: bool
    next*: GenNext[T]

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

proc newIter*[T](genNext: GenNext[T], isFinished: IsFinished, finishOnErr: bool = true): Iter[T] =
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

proc newIter*[U, V, S: Ordinal](a: U, b: V, step: S = 1): Iter[U] =
  ## Creates new Iter in range a..b with specified step (default 1)
  ##

  var i = a

  proc genNext(): U =
    let u = i
    inc(i, step)
    u

  proc isFinished(): bool =
    (step > 0 and i > b) or
      (step < 0 and i < b)

  newIter(genNext, isFinished)

proc newIter*[U, V: Ordinal](slice: HSlice[U, V]): Iter[U] =
  ## Creates new Iter from slice
  ##

  newIter(slice.a.int, slice.b.int, 1)

proc newIter*[T](items: seq[T]): Iter[T] =
  ## Creates new Iter from items
  ##

  newIter(0..<items.len)
    .map((i: int) => items[i])

proc emptyIter*[T](): Iter[T] =
  ## Creates an empty Iter
  ##

  proc genNext(): T {.upraises: [CatchableError].} =
    raise newException(CatchableError, "Next item requested from an empty Iter")
  proc isFinished(): bool = true

  newIter(genNext, isFinished)

proc map*[T, U](iter: Iter[T], fn: Function[T, U]): Iter[U] =
  newIter(
    genNext    = () => fn(iter.next()),
    isFinished = () => iter.finished
  )

proc mapFilter*[T, U](iter: Iter[T], mapPredicate: Function[T, Option[U]]): Iter[U] =
  var nextU: Option[U]

  proc tryFetch(): void =
    nextU = U.none
    while not iter.finished:
      let t = iter.next()
      if u =? mapPredicate(t):
        nextU = some(u)
        break

  proc genNext(): U =
    let u = nextU.unsafeGet
    tryFetch()
    return u

  proc isFinished(): bool =
    nextU.isNone

  tryFetch()
  newIter(genNext, isFinished)

proc filter*[T](iter: Iter[T], predicate: Function[T, bool]): Iter[T] =
  proc wrappedPredicate(t: T): Option[T] =
    if predicate(t):
      some(t)
    else:
      T.none

  mapFilter[T, T](iter, wrappedPredicate)
