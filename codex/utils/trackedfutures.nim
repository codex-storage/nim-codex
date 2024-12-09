import std/tables
import pkg/chronos

import ../logutils

{.push raises: [].}

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

  proc cb(udata: pointer) =
    self.removeFuture(fut)

  fut.addCallback(cb)

  return fut

proc track*[T, U](future: Future[T], self: U): Future[T] =
  ## Convenience method that allows chaining future, eg:
  ## `await someFut().track(sales)`, where `sales` has declared a
  ## `trackedFutures` property.
  self.trackedFutures.track(future)

proc cancelTracked*(self: TrackedFutures) {.async: (raises: []).} =
  self.cancelling = true

  trace "cancelling tracked futures"

  var cancellations: seq[FutureBase]
  for future in self.futures.values:
    if not future.isNil and not future.finished:
      cancellations.add future.cancelAndWait()

  await noCancel allFutures cancellations

  self.futures.clear()
  self.cancelling = false
