import std/times
import pkg/chronos
import ./clock

type
  SystemClock* = ref object of Clock

method now*(clock: SystemClock): Future[SecondsSince1970] {.async.} =
  let now = times.now().utc
  now.toTime().toUnix()
