import pkg/asynctest
import pkg/questionable
import pkg/chronos
import codex/utils/asyncstatemachine
import ../helpers/eventually

type 
  TestState = ref object of AsyncState
  State1 = ref object of TestState
  State2 = ref object of TestState
  State3 = ref object of TestState

var state1Invoked = 0
var state2Invoked = 0
var state2Cancelled = 0
var state3Invoked = 0

method onMoveToNextStateEvent*(state: TestState): ?AsyncState {.base.} = 
  discard

method run(state: State1): Future[?AsyncState] {.async.} = 
  inc state1Invoked
  return some AsyncState(State2.new())

method run(state: State2): Future[?AsyncState] {.async.} = 
  inc state2Invoked
  try:
    await sleepAsync(1.hours)
  except CancelledError:
    inc state2Cancelled


method onMoveToNextStateEvent(state: State2): ?AsyncState =
  return some AsyncState(State3.new())

method run(state: State3): Future[?AsyncState] {.async.} = 
  inc state3Invoked

suite "async state machines":
  var machine: AsyncStateMachine
  var state1, state2: AsyncState

  setup:
    state1Invoked = 0
    state2Invoked = 0
    state2Cancelled = 0
    state3Invoked = 0
    machine = AsyncStateMachine.new()
    state1 = State1.new()
    state2 = State2.new()

  test "should call run on start state":
    machine.start(state1)
    check eventually state1Invoked == 1

  test "moves to next state when run completes":
    machine.start(state1)
    check eventually state2Invoked == 1

  test "state2 moves to state3 on event":
    machine.start(state2)

    proc moveToNextStateEvent(state: AsyncState): ?AsyncState =
      TestState(state).onMoveToNextStateEvent()

    machine.schedule(Event(moveToNextStateEvent))

    check eventually state3Invoked == 1

  test "state transition will cancel the running state":
    machine.start(state2)

    proc moveToNextStateEvent(state: AsyncState): ?AsyncState =
      TestState(state).onMoveToNextStateEvent()

    machine.schedule(Event(moveToNextStateEvent))

    check eventually state2Cancelled == 1