import pkg/questionable

import pkg/chronos
import pkg/asynctest

import codex/utils/timer
import ../helpers/eventually


suite "Timer":
  var output: string
  var numbersState = 0
  var lettersState = 'a'

  proc numbersCallback() =
    output &= $numbersState
    inc numbersState

  proc lettersCallback() =
    output &= $lettersState
    inc lettersState

  setup:
    output = ""
    numbersState = 0
    lettersState = 'a'

  test "Start timer1 should execute callback":
    let t1 = Timer.new()
    t1.start(numbersCallback, 1.seconds)

    check eventually output == "0"
    