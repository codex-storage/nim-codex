import pkg/questionable

import pkg/chronos
import pkg/asynctest

import codex/utils/timer
import ../helpers/eventually


suite "Timer":
  var timer1: Timer
  var timer2: Timer
  var output: string
  var numbersState = 0
  var lettersState = 'a'

  proc numbersCallback(): Future[void] {.async.} =
    output &= $numbersState
    inc numbersState

  proc lettersCallback(): Future[void] {.async.} =
    output &= $lettersState
    inc lettersState

  proc exceptionCallback(): Future[void] {.async.} =
    raise newException(Defect, "Test Exception")

  setup:
    timer1 = Timer.new(numbersCallback, 10.milliseconds)
    timer2 = Timer.new(lettersCallback, 10.milliseconds)

    output = ""
    numbersState = 0
    lettersState = 'a'

  teardown:
    await timer1.stop()
    await timer2.stop()

  test "Start timer1 should execute callback":
    timer1.start()
    check eventually output == "0"

  test "Start timer1 should execute callback multiple times":
    timer1.start()
    check eventually output == "012"

  test "Starting timer1 multiple times has no impact":
    timer1.start()
    timer1.start()
    timer1.start()
    check eventually output == "01234"

  test "Stop timer1 should stop execution of the callback":
    timer1.start()
    check eventually output == "012"
    await timer1.stop()
    await sleepAsync(30.milliseconds)
    let stoppedOutput = output
    await sleepAsync(30.milliseconds)
    check output == stoppedOutput

  test "Exceptions raised in timer callback are handled":
    let timer = Timer.new(exceptionCallback, 10.milliseconds)
    timer.start()
    await sleepAsync(30.milliseconds)
    await timer.stop()

  test "Starting both timers should execute callbacks sequentially":
    timer1.start()
    timer2.start()
    check eventually output == "0a1b2c3d4e"
