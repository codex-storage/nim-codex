import pkg/asynctest
import pkg/questionable
import pkg/chronos
import codex/utils/asyncstatemachine
import ../helpers/eventually

type 
  TestState = ref object of AsyncState
  State1 = ref object of AsyncState
  State2 = ref object of AsyncState

var runInvoked = 0
var state2runInvoked = 0

method run(state: TestState): Future[?AsyncState] {.async.} = 
  inc runInvoked

method run(state: State1): Future[?AsyncState] {.async.} = 
  return some AsyncState(State2.new())

method run(state: State2): Future[?AsyncState] {.async.} = 
  inc state2runInvoked

suite "async state machines":
  setup:
    runInvoked = 0
    state2runInvoked = 0

  test "creates async state machine":
    let sm = AsyncStateMachine.new()
    check sm != nil

  test "should call run on start state":
    let sm = AsyncStateMachine.new()
    let testState = TestState.new()
    
    sm.start(testState)

    check eventually runInvoked == 1

  test "moves to next state when run completes":
    let sm = AsyncStateMachine.new()
    let state1 = State1.new()
    let state2 = State2.new()

    sm.start(state1)

    check eventually state2runInvoked == 1

