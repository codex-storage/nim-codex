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
import pkg/upraises

type
  TimerCallback* = proc(): Future[void] {.gcsafe, upraises:[].}
  Timer* = ref object of RootObj
    callback: TimerCallback
    interval: Duration
    name: string
    loopFuture: Future[void]

proc new*(T: type Timer, timerName = "Unnamed Timer"): T =
  T(
    name: timerName
  )

proc timerLoop(timer: Timer) {.async.} =
  try:
    while true:
      await timer.callback()
      await sleepAsync(timer.interval)
  except CatchableError as exc:
    error "Timer caught unhandled exception: ", name=timer.name, msg=exc.msg

method start*(timer: Timer, callback: TimerCallback, interval: Duration) {.base.} =
  if timer.loopFuture != nil:
    return
  trace "Timer starting: ", name=timer.name
  timer.callback = callback
  timer.interval = interval
  timer.loopFuture = timerLoop(timer)

method stop*(timer: Timer) {.async, base.} =
  if timer.loopFuture != nil:
    trace "Timer stopping: ", name=timer.name
    await timer.loopFuture.cancelAndWait()
    timer.loopFuture = nil
