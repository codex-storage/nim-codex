## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos

import codex/utils/timer

type
  MockTimer*[T] = ref object of Timer[T]
    startCalled*: int
    stopCalled*: int

proc new*(T: type MockTimer): T =
  T(
    startCalled: 0,
    stopCalled: 0
  )

method start*[T](mockTimer: MockTimer[T], user: T, callback: timer.TimerCallback[T], interval: Duration) =
  echo "mock timer start"
  mockTimer.callback = callback
  mockTimer.interval = interval
  mockTimer.user = user
  inc mockTimer.startCalled

method stop*(mockTimer: MockTimer) {.async.} =
  inc mockTimer.stopCalled

method invokeCallback*[T](mockTimer: MockTimer[T]) {.async, base.} =
  await mockTimer.callback(mockTimer.user)
