import pkg/chronos

type
  Clock* = ref object of RootObj
  SecondsSince1970* = int64
  Timeout* = object of CatchableError

method now*(clock: Clock): SecondsSince1970 {.base.} =
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
