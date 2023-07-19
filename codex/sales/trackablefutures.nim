import std/tables
import pkg/chronicles
import pkg/chronos
import ../utils/then

type
  TrackableFutures* = ref object of RootObj
    futures*: Table[uint, seq[FutureBase]]
    running*: bool

proc track*[T](fut: Future[T], t: TrackableFutures): Future[T] =
  fut.finally(
    proc() =
      if t.running and not fut.isNil:
        t.futures.del(fut.id)
  )
  t.futures[fut.id] = @[FutureBase(fut)]
  return fut

proc track*[T, U](fut1: Future[T], t: TrackableFutures, fut2: Future[U]) =
  fut1.finally(
    proc() =
      if t.running and not fut1.isNil:
        t.futures.del(fut1.id)
  )
  t.futures[fut1.id] = @[FutureBase(fut1), FutureBase(fut2)]

proc cancelTracked*(self: TrackableFutures) {.async.} =
  for futures in self.futures.values:
    for future in futures:
      if not future.isNil and not future.finished:
        trace "cancelling tracked future", id = future.id
        await future.cancelAndWait()