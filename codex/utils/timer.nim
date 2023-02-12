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
# import pkg/chronicles
import pkg/questionable
import pkg/upraises

type
  TimerCallback*[T] = proc(user: T): Future[void] {.gcsafe, upraises:[].}
  Timer*[T] = ref object of RootObj
    ## these are now public for testing and I don't like it.
    callback*: TimerCallback[T]
    interval*: Duration
    user: T
    name: string
    loopFuture: ?Future[void]

proc new*(T: type Timer, timerName = "Unnamed Timer"): T =
  T(
    name: timerName,
    loopFuture: Future[void].none
  )

proc timerLoop[T](timer: Timer[T]) {.async.} =
  try:
    while true:
      await sleepAsync(timer.interval)
      await timer.callback(timer.user)
  except Exception as exc:
    # error "Timer: ", timer.name, " caught unhandled exception: ", exc
    # Chronicles breaks when used in a proc with type-argument? Plz help
    discard

method start*[T](timer: Timer[T], user: T, callback: TimerCallback, interval: Duration) {.base.} =
  if timer.loopFuture.isSome():
    return
  # trace "Timer starting: ", timer.name
  timer.user = user
  timer.callback = callback
  timer.interval = interval
  let future = timerLoop(timer)
  timer.loopFuture = future.some
  asyncSpawn future

method stop*[T](timer: Timer[T]) {.async, base.} =
  if f =? timer.loopFuture:
    # trace "Timer stopping: ", timer.name
    await f.cancelAndWait()
    timer.loopFuture = Future[void].none
