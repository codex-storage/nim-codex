import pkg/asynctest
import pkg/questionable
import pkg/chronos
import codex/utils/asyncstatemachine
import ../helpers/eventually

type 
  AsyncTestState = ref object of AsyncState
  State1 = ref object of AsyncTestState
  State2 = ref object of AsyncTestState
  State3 = ref object of AsyncTestState

var state1runInvoked = 0
var state2runInvoked = 0
var state3runInvoked = 0

method onMoveToNextStateEvent*(state: AsyncTestState): ?AsyncState {.base.} = 
  discard

method run(state: State1): Future[?AsyncState] {.async.} = 
  inc state1runInvoked
  return some AsyncState(State2.new())

method run(state: State2): Future[?AsyncState] {.async.} = 
  inc state2runInvoked

method onMoveToNextStateEvent(state: State2): ?AsyncState =
  return some AsyncState(State3.new())

method run(state: State3): Future[?AsyncState] {.async.} = 
  inc state3runInvoked

suite "async state machines":
  var machine: AsyncStateMachine
  var state1, state2: AsyncState

  setup:
    state1runInvoked = 0
    state2runInvoked = 0
    state3runInvoked = 0
    machine = AsyncStateMachine.new()
    state1 = State1.new()
    state2 = State2.new()

  test "should call run on start state":
    machine.start(state1)
    check eventually state1runInvoked == 1

  test "moves to next state when run completes":
    machine.start(state1)
    check eventually state2runInvoked == 1

  test "state2 moves to state3 on event":
    machine.start(state2)

    proc moveToNextStateEvent(state: AsyncState): ?AsyncState =
      AsyncTestState(state).onMoveToNextStateEvent()

    machine.schedule(Event(moveToNextStateEvent))

    check eventually state3runInvoked == 1
