## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.


## Timer
## Used to execute a callback in a loop

import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/upraises

type
  TimerCallback* = proc(): Future[void] {.gcsafe, upraises:[].}
  Timer* = ref object
    callback: TimerCallback
    interval: Duration
    name: string
    loopFuture: ?Future[void]

proc new*(T: type Timer, callback: TimerCallback, interval: Duration, timerName = "Unnamed Timer"): T =
  T(
    callback: callback,
    interval: interval,
    name: timerName,
    loopFuture: Future[void].none
  )

proc timerLoop(timer: Timer) {.async.} =
  try:
    while true:
      await sleepAsync(timer.interval)
      await timer.callback()
  except Exception as exc:
    error "Timer: ", timer.name, " caught unhandled exception: ", exc

method start*(timer: Timer) =
  if timer.loopFuture.isSome():
    return
  trace "Timer starting: ", timer.name
  timer.loopFuture = timerLoop(timer).some
  asyncSpawn !timer.loopFuture

method stop*(timer: Timer) {.async.} =
  if f =? timer.loopFuture:
    trace "Timer stopping: ", timer.name
    await f.cancelAndWait()
    timer.loopFuture = Future[void].none
