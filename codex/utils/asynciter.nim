import std/sugar
import pkg/questionable
import pkg/chronos
import pkg/upraises

type
  Function*[T, U] = proc(fut: T): U {.upraises: [CatchableError], gcsafe, closure.}
  IsFinished* = proc(): bool {.upraises: [], gcsafe, closure.}
  GenNext*[T] = proc(): T {.upraises: [CatchableError], gcsafe, closure.}

  Iter*[T] = ref object
    finished: bool
    next*: GenNext[T]

  AsyncIter*[T] = Iter[Future[T]]

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

proc map*[T, U](fut: Future[T], fn: Function[T, U]): Future[U] {.async.} =
  let t = await fut
  fn(t)

proc new*[T](
  _: type Iter,
  genNext: GenNext[T],
  isFinished: IsFinished,
  finishOnErr: bool = true): Iter[T] =
  var iter = Iter[T]()

  proc next(): T {.upraises: [CatchableError].} =
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
      raise newException(CatchableError, "Iterator is finished but next item was requested")

  if isFinished():
    iter.finish

  iter.next = next
  return iter

proc fromItems*[T](_: type Iter, items: openArray[T]): Iter[T] =
  ## Create new iterator from items
  ##

  Iter.fromSlice(0..<items.len)
    .map((i) => items[i])

proc fromSlice*[U, V: Ordinal](_: type Iter, slice: HSlice[U, V]): Iter[U] =
  ## Creates new iterator from slice
  ##

  Iter.fromRange(slice.a.int, slice.b.int, 1)

proc fromRange*[U, V, S: Ordinal](_: type Iter, a: U, b: V, step: S = 1): Iter[U] =
  ## Creates new iterator in range a..b with specified step (default 1)
  ##

  var i = a

  proc genNext(): U =
    let u = i
    inc(i, step)
    u

  proc isFinished(): bool =
    (step > 0 and i > b) or
      (step < 0 and i < b)

  Iter.new(genNext, isFinished)

proc map*[T, U](iter: Iter[T], fn: Function[T, U]): Iter[U] =
  Iter.new(
    genNext    = () => fn(iter.next()),
    isFinished = () => iter.finished
  )

proc filter*[T](iter: Iter[T], predicate: Function[T, bool]): Iter[T] =
  var nextItem: T

  proc tryFetch(): void =
    while not iter.finished:
      let item = iter.next()
      if predicate(item):
        nextItem = some(item)
        break

  proc genNext(): T =
    let t = nextItem
    tryFetch()
    return t

  proc isFinished(): bool =
    iter.finished

  tryFetch()
  Iter.new(genNext, isFinished)

proc prefetch*[T](iter: Iter[T], n: Positive): Iter[T] =
  var ringBuf = newSeq[T](n)
  var iterLen = int.high
  var i = 0
  proc tryFetch(j: int): void =
    if not iter.finished:
      let item = iter.next()
      ringBuf[j mod n] = item
      if iter.finished:
        iterLen = min(j + 1, iterLen)
    else:
      if j == 0:
        iterLen = 0

  proc genNext(): T =
    let item = ringBuf[i mod n]
    tryFetch(i + n)
    inc i
    return item

  proc isFinished(): bool =
    i >= iterLen

  # initialize ringBuf with n prefetched values
  for j in 0..<n:
    tryFetch(j)

  Iter.new(genNext, isFinished)
