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

proc cancelTracked*(self: TrackableFutures) {.async.} =
  for futures in self.futures.values:
    for future in futures:
      if not future.isNil and not future.finished:
        trace "cancelling tracked future", id = future.id
        await future.cancelAndWait()