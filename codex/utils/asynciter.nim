import pkg/questionable
import pkg/chronos
import pkg/upraises

type
  MapItem*[T, U] = proc(fut: T): U {.upraises: [CatchableError], gcsafe, closure.}
  NextItem*[T] = proc(): T {.upraises: [CatchableError], gcsafe, closure.}
  Iter*[T] = ref object
    finished*: bool
    next*: NextItem[T]
  AsyncIter*[T] = Iter[Future[T]]

proc finish*[T](self: Iter[T]): void =
  self.finished = true

proc finished*[T](self: Iter[T]): bool =
  self.finished

iterator items*[T](self: Iter[T]): T =
  while not self.finished:
    yield self.next()

proc map*[T, U](wrappedIter: Iter[T], mapItem: MapItem[T, U]): Iter[U] =
  var iter = Iter[U]()

  proc checkFinish(): void =
    if wrappedIter.finished:
      iter.finish

  checkFinish()

  proc next(): U {.upraises: [CatchableError].} =
    if not iter.finished:
      let fut = wrappedIter.next()
      checkFinish()
      return mapItem(fut)
    else:
      raise newException(CatchableError, "Iterator finished, but next element was requested")

  iter.next = next
  return iter

proc prefetch*[T](wrappedIter: Iter[T], n: Positive): Iter[T] =

  var ringBuf = newSeq[T](n)
  var wrappedLen = int.high

  var iter = Iter[T]()

  proc tryFetch(i: int): void =
    if not wrappedIter.finished:
      let res = wrappedIter.next()
      ringBuf[i mod n] = res
      if wrappedIter.finished:
        wrappedLen = min(i + 1, wrappedLen)
    else:
      if i == 0:
        wrappedLen = 0

  proc checkLen(i: int): void =
    if i >= wrappedLen:
      iter.finish

  # initialize buf with n prefetched values
  for i in 0..<n:
    tryFetch(i)

  checkLen(0)

  var i = 0
  proc next(): T {.upraises: [CatchableError].} =
    if not iter.finished:
      let fut = ringBuf[i mod n]
      # prefetch a value
      tryFetch(i + n)
      inc i
      checkLen(i)
      
      return fut
    else:
      raise newException(CatchableError, "Iterator finished, but next element was requested")
  
  iter.next = next
  return iter

