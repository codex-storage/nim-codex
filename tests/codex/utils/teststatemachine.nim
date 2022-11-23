import std/unittest
import pkg/questionable
import codex/utils/statemachine

type
  Light = ref object of StateMachine
  On = ref object of State
  Off = ref object of State

var enteredOn: bool
var exitedOn: bool

method enter(state: On) =
  enteredOn = true

method exit(state: On) =
  exitedOn = true

suite "state machines":

  setup:
    enteredOn = false
    exitedOn = false

  test "calls `enter` when entering state":
    Light().switch(On())
    check enteredOn

  test "calls `exit` when exiting state":
    let light = Light()
    light.switch(On())
    check not exitedOn
    light.switch(Off())
    check exitedOn

  test "allows access to state machine from state":
    let light = Light()
    let on = On()
    check not isSome on.context
    light.switch(on)
    check on.context == some StateMachine(light)

  test "removes access to state machine when state exited":
    let light = Light()
    let on = On()
    light.switch(on)
    light.switch(Off())
    check not isSome on.context
