import pkg/chronos

type
  Clock* = ref object of RootObj
  SecondsSince1970* = int64

method now*(clock: Clock): SecondsSince1970 {.base.} =
  raiseAssert "not implemented"

proc waitUntil*(clock: Clock, time: SecondsSince1970) {.async.} =
  while clock.now() < time:
    await sleepAsync(1.seconds)
