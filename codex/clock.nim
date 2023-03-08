import pkg/chronos
import pkg/stew/endians2
import pkg/upraises

type
  Clock* = ref object of RootObj
  SecondsSince1970* = int64
  Timeout* = object of CatchableError

method now*(clock: Clock): SecondsSince1970 {.base, upraises: [].} =
  raiseAssert "not implemented"

proc waitUntil*(clock: Clock, time: SecondsSince1970) {.async.} =
  while clock.now() < time:
    await sleepAsync(1.seconds)

proc withTimeout*(future: Future[void],
                  clock: Clock,
                  expiry: SecondsSince1970) {.async.} =
  let timeout = clock.waitUntil(expiry)
  try:
    await future or timeout
  finally:
    await timeout.cancelAndWait()
  if not future.completed:
    await future.cancelAndWait()
    raise newException(Timeout, "Timed out")

proc toBytes*(i: SecondsSince1970): seq[byte] =
  let asUint = cast[uint64](i)
  @(asUint.toBytes)

proc toSecondsSince1970*(bytes: seq[byte]): SecondsSince1970 =
  let asUint = uint64.fromBytes(bytes)
  cast[int64](asUint)
