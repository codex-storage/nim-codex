import pkg/chronos

import pkg/storage/errors

import ../asynctest
import ../checktest

asyncchecksuite "allDone":
  test "empty sequence completes immediately with all groups empty":
    let futs = newSeq[Future[void]]()
    let res = await allDone[void](futs)
    check res.completed.len == 0
    check res.failed.len == 0
    check res.cancelled.len == 0

  test "all completed futures go in the completed group":
    let
      fut1 = Future[void].Raising([CancelledError]).init("f1")
      fut2 = Future[void].Raising([CancelledError]).init("f2")
    fut1.complete()
    fut2.complete()
    let res = await allDone[void](@[fut1, fut2])
    check res.completed.len == 2
    check res.failed.len == 0
    check res.cancelled.len == 0

  test "all failed futures go in the failed group":
    let
      fut1 = Future[void].Raising([CancelledError, CatchableError]).init("f1")
      fut2 = Future[void].Raising([CancelledError, CatchableError]).init("f2")
    fut1.fail(newException(CatchableError, "e1"))
    fut2.fail(newException(CatchableError, "e2"))
    let res = await allDone[void](@[fut1, fut2])
    check res.completed.len == 0
    check res.failed.len == 2
    check res.cancelled.len == 0

  test "all cancelled futures go in the cancelled group":
    let
      fut1 = Future[void].Raising([CancelledError]).init("f1")
      fut2 = Future[void].Raising([CancelledError]).init("f2")
    await fut1.cancelAndWait()
    await fut2.cancelAndWait()
    let res = await allDone[void](@[fut1, fut2])
    check res.completed.len == 0
    check res.failed.len == 0
    check res.cancelled.len == 2

  test "futures are grouped by their end state":
    let
      completed = Future[void].Raising([CancelledError, CatchableError]).init("completed")
      failed = Future[void].Raising([CancelledError, CatchableError]).init("failed")
      cancelled = Future[void].Raising([CancelledError, CatchableError]).init("cancelled")
    completed.complete()
    failed.fail(newException(CatchableError, "e"))
    await cancelled.cancelAndWait()
    let res = await allDone[void](@[completed, failed, cancelled])
    check res.completed.len == 1
    check res.failed.len == 1
    check res.cancelled.len == 1
    check res.completed[0] == completed
    check res.failed[0] == failed
    check res.cancelled[0] == cancelled

  test "order within each group matches the original input order":
    let
      fut1 = Future[void].Raising([CancelledError]).init("f1")
      fut2 = Future[void].Raising([CancelledError]).init("f2")
      fut3 = Future[void].Raising([CancelledError]).init("f3")
    fut1.complete()
    fut2.complete()
    fut3.complete()
    let res = await allDone[void](@[fut1, fut2, fut3])
    check res.completed.len == 3
    check res.completed[0] == fut1
    check res.completed[1] == fut2
    check res.completed[2] == fut3

  test "cancelling allDone does not cancel the awaited futures":
    let
      fut1 = Future[void].Raising([CancelledError]).init("f1")
      fut2 = Future[void].Raising([CancelledError]).init("f2")
    let doneFut = allDone[void](@[fut1, fut2])
    await doneFut.cancelAndWait()
    check doneFut.cancelled
    check not fut1.cancelled
    check not fut2.cancelled
    fut1.complete()
    fut2.complete()

  test "failed Result is grouped as a failed future":
    let
      fut1 = Future[Result[int, string]].Raising([CancelledError]).init("f1")
      fut2 = Future[Result[int, string]].Raising([CancelledError]).init("f2")
    fut1.complete(Result[int, string].ok(42))
    fut2.complete(Result[int, string].err("error"))
    let res = await allDone[Result[int, string]](@[fut1, fut2])
    check res.completed.len == 1
    check res.failed.len == 1
    check res.cancelled.len == 0
    check res.completed[0] == fut1
    check res.failed[0] == fut2
