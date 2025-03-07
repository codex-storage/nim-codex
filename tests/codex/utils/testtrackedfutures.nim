import pkg/chronos
import codex/utils/trackedfutures

import ../../asynctest
import ../helpers

type Module = object
  trackedFutures: TrackedFutures

asyncchecksuite "tracked futures":
  var module: Module

  setup:
    module = Module(trackedFutures: TrackedFutures.new())

  test "starts with zero tracked futures":
    check module.trackedFutures.len == 0

  test "tracks unfinished futures":
    let fut = Future[void].Raising([]).init("test", {FutureFlag.OwnCancelSchedule})
    module.trackedFutures.track(fut)
    check module.trackedFutures.len == 1

  test "does not track completed futures":
    let fut = Future[void].Raising([]).init("test", {FutureFlag.OwnCancelSchedule})
    fut.complete()
    module.trackedFutures.track(fut)
    check module.trackedFutures.len == 0

  test "does not track cancelled futures":
    let fut = Future[void].Raising([]).init("test", {FutureFlag.OwnCancelSchedule})
    fut.cancelCallback = proc(data: pointer) =
      fut.cancelAndSchedule() # manually schedule the cancel

    await fut.cancelAndWait()
    module.trackedFutures.track(fut)
    check eventually module.trackedFutures.len == 0

  test "removes tracked future when finished":
    let fut = Future[void].Raising([]).init("test", {FutureFlag.OwnCancelSchedule})
    module.trackedFutures.track(fut)
    check module.trackedFutures.len == 1
    fut.complete()
    check eventually module.trackedFutures.len == 0

  test "removes tracked future when cancelled":
    let fut = Future[void].Raising([]).init("test", {FutureFlag.OwnCancelSchedule})
    fut.cancelCallback = proc(data: pointer) =
      fut.cancelAndSchedule() # manually schedule the cancel

    module.trackedFutures.track(fut)
    check module.trackedFutures.len == 1
    await fut.cancelAndWait()
    check eventually module.trackedFutures.len == 0

  test "completed and removes future on cancel":
    let fut = Future[void].Raising([]).init("test", {FutureFlag.OwnCancelSchedule})
    fut.cancelCallback = proc(data: pointer) =
      fut.complete()

    module.trackedFutures.track(fut)
    check module.trackedFutures.len == 1
    await fut.cancelAndWait()
    check eventually module.trackedFutures.len == 0

  test "cancels and removes all tracked futures":
    let fut1 = Future[void].Raising([]).init("test1", {FutureFlag.OwnCancelSchedule})
    fut1.cancelCallback = proc(data: pointer) =
      fut1.cancelAndSchedule() # manually schedule the cancel

    let fut2 = Future[void].Raising([]).init("test2", {FutureFlag.OwnCancelSchedule})
    fut2.cancelCallback = proc(data: pointer) =
      fut2.cancelAndSchedule() # manually schedule the cancel

    let fut3 = Future[void].Raising([]).init("test3", {FutureFlag.OwnCancelSchedule})
    fut3.cancelCallback = proc(data: pointer) =
      fut3.cancelAndSchedule() # manually schedule the cancel

    module.trackedFutures.track(fut1)
    check module.trackedFutures.len == 1
    module.trackedFutures.track(fut2)
    check module.trackedFutures.len == 2
    module.trackedFutures.track(fut3)
    check module.trackedFutures.len == 3
    await module.trackedFutures.cancelTracked()
    check eventually fut1.cancelled
    check eventually fut2.cancelled
    check eventually fut3.cancelled
    check eventually module.trackedFutures.len == 0
