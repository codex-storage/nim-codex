import std/sugar
import std/tables
import pkg/chronicles
import pkg/chronos
import ../utils/then

type
  TrackedFutures* = ref object
    futures: Table[uint, FutureBase]
    cancelling: bool

logScope:
  topics = "trackable futures"

proc track*[T](self: TrackedFutures, fut: Future[T]): Future[T] =
  logScope:
    id = fut.id

  proc removeFuture() =
    if not self.cancelling and not fut.isNil:
      trace "removing tracked future"
      self.futures.del(fut.id)

  proc removes(val: T) {.gcsafe, upraises: [].} =
    removeFuture()
  proc catchErr(err: ref CatchableError) {.gcsafe, upraises: [].} =
    removeFuture()

  fut
    .then(removes)
    .catch(catchErr)

  trace "tracking future"
  self.futures[fut.id] = FutureBase(fut)
  return fut

proc track*[T, U](future: Future[T], self: U): Future[T] =
  ## Convenience method that allows chaining future, eg:
  ## `await someFut().track(sales)`, where `sales` has declared a
  ## `trackedFutures` property.
  self.trackedFutures.track(future)

proc cancelTracked*(self: TrackedFutures) {.async.} =
  self.cancelling = true

  for future in self.futures.values:
    if not future.isNil and not future.finished:
      trace "cancelling tracked future", id = future.id
      await future.cancelAndWait()

  self.cancelling = false
