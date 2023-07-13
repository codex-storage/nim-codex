import std/os
import std/sequtils
import pkg/asynctest
import pkg/chronicles # delete me
import pkg/chronos
import pkg/codex/utils/then

proc nestedAsyncProc {.async.} =
  echo "START running nested async proc..."
  await sleepAsync(1000.millis)
  echo "END running nested async proc..."

proc asyncProc1 {.async.} =
  await nestedAsyncProc()

proc cb(udata:pointer) =
  let fut = cast[FutureBase](udata)
  if not fut.finished:
    echo "fut not finished"

  if fut.cancelled:
    echo "fut cancelled"

  if fut.failed:
    echo "fut failed"

proc run {.async.} =
  let fut = asyncProc1()
  fut.addCallback(cb)
  await sleepAsync(500.millis)
  await fut.cancelAndWait()

waitFor run()

proc asyncProc(): Future[int] {.async.} =
  await sleepAsync(1.millis)
  return 1

asyncProc()
  .then(proc(i: int) = echo "returned ", i)
  .catch(proc(e: ref CatchableError) = doAssert false, "will not be triggered")

# outputs "returned 1"

proc asyncProcWithError(): Future[int] {.async.} =
  await sleepAsync(1.millis)
  raise newException(ValueError, "some error")

asyncProcWithError()
  .then(proc(i: int) = doAssert false, "will not be triggered")
  .catch(proc(e: ref CatchableError) = echo "errored: ", e.msg)

# outputs "errored: some error"
waitFor sleepAsync(2.millis)
