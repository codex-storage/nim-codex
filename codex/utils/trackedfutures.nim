import std/sugar
import std/tables
import pkg/chronos

import ../logutils
import ../utils/then

type
  TrackedFutures* = ref object
    futures: Table[uint, FutureBase]
    cancelling: bool

logScope:
  topics = "trackable futures"

proc len*(self: TrackedFutures): int = self.futures.len

proc removeFuture(self: TrackedFutures, future: FutureBase) =
  if not self.cancelling and not future.isNil:
    self.futures.del(future.id)

proc track*[T](self: TrackedFutures, fut: Future[T]): Future[T] =
  if self.cancelling:
    return fut

  self.futures[fut.id] = FutureBase(fut)

  fut
    .then((val: T) => self.removeFuture(fut))
    .cancelled(() => self.removeFuture(fut))
    .catch((e: ref CatchableError) => self.removeFuture(fut))

  return fut

proc track*[T, U](future: Future[T], self: U): Future[T] =
  ## Convenience method that allows chaining future, eg:
  ## `await someFut().track(sales)`, where `sales` has declared a
  ## `trackedFutures` property.
  self.trackedFutures.track(future)

proc cancelTracked*(self: TrackedFutures) {.async.} =
  self.cancelling = true

  trace "cancelling tracked futures"

  for future in self.futures.values:
    if not future.isNil and not future.finished:
      trace "cancelling tracked future", id = future.id
      await future.cancelAndWait()

  self.futures.clear()
  self.cancelling = false
