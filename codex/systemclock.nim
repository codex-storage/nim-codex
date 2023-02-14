import std/times
import codex/clock
import pkg/upraises

type
  SystemClock* = ref object of Clock

method now*(clock: SystemClock): SecondsSince1970 {.upraises: [].} =
  let now = times.now().utc
  now.toTime().toUnix()
