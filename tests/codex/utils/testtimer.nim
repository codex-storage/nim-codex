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

  proc numbersCallback() =
    output &= $numbersState
    inc numbersState

  proc lettersCallback() =
    output &= $lettersState
    inc lettersState

  proc exceptionCallback() =
    raise newException(Defect, "Test Exception")

  setup:
    timer1 = Timer.new(numbersCallback, 10.milliseconds)
    timer2 = Timer.new(lettersCallback, 10.milliseconds)

    output = ""
    numbersState = 0
    lettersState = 'a'

  teardown:
    timer1.stop()
    timer2.stop()

  test "Start timer1 should execute callback":
    timer1.start()
    check eventually output == "0"

  test "Start timer1 should execute callback multiple times":
    timer1.start()
    check eventually output == "012"

  test "Stop timer1 should stop execution of the callback":
    timer1.start()
    check eventually output == "012"
    timer1.stop()
    await sleepAsync(30.milliseconds)
    let stoppedOutput = output
    await sleepAsync(30.milliseconds)
    check output == stoppedOutput

  test "Exceptions raised in timer callback are handled":
    let timer = Timer.new(exceptionCallback, 10.milliseconds)
    timer.start()
    await sleepAsync(30.milliseconds)
    timer.stop()

  test "Starting both timers should execute callbacks sequentially":
    timer1.start()
    timer2.start()
    check eventually output == "0a1b2c3d4e"
