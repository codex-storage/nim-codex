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

import ../../asynctest
import ../helpers

asyncchecksuite "Timer":
  var timer1: Timer
  var timer2: Timer
  var output: string
  var numbersState = 0
  var lettersState = 'a'

  proc numbersCallback(): Future[void] {.async: (raises: []).} =
    output &= $numbersState
    inc numbersState

  proc lettersCallback(): Future[void] {.async: (raises: []).} =
    output &= $lettersState
    inc lettersState

  proc startNumbersTimer() =
    timer1.start(numbersCallback, 10.milliseconds)

  proc startLettersTimer() =
    timer2.start(lettersCallback, 10.milliseconds)

  setup:
    timer1 = Timer.new()
    timer2 = Timer.new()

    output = ""
    numbersState = 0
    lettersState = 'a'

  teardown:
    await timer1.stop()
    await timer2.stop()

  test "Start timer1 should execute callback":
    startNumbersTimer()
    check eventually(output == "0", pollInterval = 10)

  test "Start timer1 should execute callback multiple times":
    startNumbersTimer()
    check eventually(output == "012", pollInterval = 10)

  test "Starting timer1 multiple times has no impact":
    startNumbersTimer()
    startNumbersTimer()
    startNumbersTimer()
    check eventually(output == "01234", pollInterval = 10)

  test "Stop timer1 should stop execution of the callback":
    startNumbersTimer()
    check eventually(output == "012", pollInterval = 10)
    await timer1.stop()
    await sleepAsync(30.milliseconds)
    let stoppedOutput = output
    await sleepAsync(30.milliseconds)
    check output == stoppedOutput

  test "Starting both timers should execute callbacks sequentially":
    startNumbersTimer()
    startLettersTimer()
    check eventually(output == "0a1b2c3d4e", pollInterval = 10)
