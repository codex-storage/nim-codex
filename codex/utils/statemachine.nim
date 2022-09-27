import pkg/questionable
import ./optionalcast

## Implementation of the the state pattern:
## https://en.wikipedia.org/wiki/State_pattern
##
## Define your own state machine and state types:
##
##     type
##       Light = ref object of StateMachine
##         color: string
##       LightState = ref object of State
##
##     let light = Light(color: "yellow")
##
## Define the states:
##
##     type
##       On = ref object of LightState
##       Off = ref object of LightState
##
## Perform actions on state entry and exit:
##
##     method enter(state: On) =
##       echo light.color, " light switched on"
##
##     method exit(state: On) =
##       echo light.color, " light no longer switched on"
##
##     light.switch(On())  # prints: 'light switched on'
##     light.switch(Off()) # prints: 'light no longer switched on'
##
##  Allow behaviour to change based on the current state:
##
##     method description*(state: LightState): string {.base.} =
##       return "a light"
##
##     method description*(state: On): string =
##       if light =? (state.context as Light):
##         return "a " & light.color & " light"
##
##     method description*(state: Off): string =
##       return "a dark light"
##
##     proc description*(light: Light): string =
##       if state =? (light.state as LightState):
##         return state.description
##
##     light.switch(On())
##     echo light.description # prints: 'a yellow light'
##     light.switch(Off())
##     echo light.description # prints 'a dark light'


export questionable
export optionalcast

type
  StateMachine* = ref object of RootObj
    state: ?State
  State* = ref object of RootObj
    context: ?StateMachine

method enter(state: State) {.base.} =
  discard

method exit(state: State) {.base.} =
  discard

func state*(machine: StateMachine): ?State =
  machine.state

func context*(state: State): ?StateMachine =
  state.context

proc switch*(machine: StateMachine, newState: State) =
  if state =? machine.state:
    state.exit()
    state.context = StateMachine.none
  machine.state = newState.some
  newState.context = machine.some
  newState.enter()

proc switch*(oldState, newState: State) =
  if context =? oldState.context:
    context.switch(newState)
