## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/questionable

import pkg/chronos
import pkg/asynctest

import codex/utils/timer
import ../helpers/eventually

type
  TestUserType = ref object

suite "Timer":
  var timer1: Timer[TestUserType]
  var timer2: Timer[TestUserType]
  var output: string
  var numbersState = 0
  var lettersState = 'a'
  var user: TestUserType
  var receivedUser: TestUserType

  proc numbersCallback(userType: TestUserType): Future[void] {.async.} =
    receivedUser = userType
    output &= $numbersState
    inc numbersState

  proc lettersCallback(userType: TestUserType): Future[void] {.async.} =
    receivedUser = userType
    output &= $lettersState
    inc lettersState

  proc exceptionCallback(userType: TestUserType): Future[void] {.async.} =
    receivedUser = userType
    raise newException(Defect, "Test Exception")

  proc startNumbersTimer() =
    timer1.start(user, numbersCallback, 10.milliseconds)

  proc startLettersTimer() =
    timer2.start(user, lettersCallback, 10.milliseconds)

  setup:
    timer1 = Timer[TestUserType].new()
    timer2 = Timer[TestUserType].new()

    output = ""
    numbersState = 0
    lettersState = 'a'
    user = TestUserType.new()

  teardown:
    await timer1.stop()
    await timer2.stop()

  test "Start timer1 should execute callback":
    startNumbersTimer()
    check eventually output == "0"

  test "Start timer1 should execute callback multiple times":
    startNumbersTimer()
    check eventually output == "012"

  test "Timer passes user object to callback":
    startNumbersTimer()
    check eventually output == "0"
    check receivedUser == user

  test "Starting timer1 multiple times has no impact":
    startNumbersTimer()
    startNumbersTimer()
    startNumbersTimer()
    check eventually output == "01234"

  test "Stop timer1 should stop execution of the callback":
    startNumbersTimer()
    check eventually output == "012"
    await timer1.stop()
    await sleepAsync(30.milliseconds)
    let stoppedOutput = output
    await sleepAsync(30.milliseconds)
    check output == stoppedOutput

  test "Exceptions raised in timer callback are handled":
    timer1.start(user, exceptionCallback, 10.milliseconds)
    await sleepAsync(30.milliseconds)
    await timer1.stop()

  test "Starting both timers should execute callbacks sequentially":
    startNumbersTimer()
    startLettersTimer()
    check eventually output == "0a1b2c3d4e"
