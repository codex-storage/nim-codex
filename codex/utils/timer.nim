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

type
  TimerCallback* = proc(): void {.gcsafe.}
  Timer* = ref object
    callback: TimerCallback
    interval: Duration
    name: string
    isRunning: bool

proc new*(T: type Timer, callback: TimerCallback, interval: Duration, timerName = "Unnamed Timer"): T =
  T(
    callback: callback,
    interval: interval,
    name: timerName,
    isRunning: false
  )

proc timerLoop(timer: Timer) {.async.} =
  try:
    while timer.isRunning:
      await sleepAsync(timer.interval)
      timer.callback()
  except Exception as exc:
    timer.isRunning = false
    error "Timer: ", timer.name, " caught unhandled exception: ", exc

method start*(timer: Timer) =
  if timer.isRunning:
    return
  trace "Timer starting: ", timer.name
  timer.isRunning = true
  asyncSpawn timerLoop(timer)

method stop*(timer: Timer) =
  if not timer.isRunning:
    return

  trace "Timer stopping: ", timer.name
  timer.isRunning = false
