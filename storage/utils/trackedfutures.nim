import std/tables
import pkg/chronos

import ../logutils

{.push raises: [].}

type
  TrackedFuture = Future[void].Raising([])
  TrackedFutures* = ref object
    futures: Table[uint, TrackedFuture]
    cancelling: bool

logScope:
  topics = "trackable futures"

proc len*(self: TrackedFutures): int =
  self.futures.len

proc removeFuture(self: TrackedFutures, future: TrackedFuture) =
  if not self.cancelling and not future.isNil:
    self.futures.del(future.id)

proc track*(self: TrackedFutures, fut: TrackedFuture) =
  if self.cancelling:
    return

  if fut.finished:
    return

  self.futures[fut.id] = fut

  proc cb(udata: pointer) =
    self.removeFuture(fut)

  fut.addCallback(cb)

proc cancelTracked*(self: TrackedFutures) {.async: (raises: []).} =
  self.cancelling = true

  trace "cancelling tracked futures", len = self.futures.len
  let cancellations = self.futures.values.toSeq.mapIt(it.cancelAndWait())
  await noCancel allFutures cancellations

  self.futures.clear()
  self.cancelling = false
