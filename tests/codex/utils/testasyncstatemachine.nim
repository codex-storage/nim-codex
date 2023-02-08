import pkg/asynctest
import pkg/questionable
import pkg/chronos
import codex/utils/asyncstatemachine
import ../helpers/eventually

type TestState = ref object of AsyncState

var runInvoked = 0

method run(state: TestState): Future[?AsyncState] = 
  inc runInvoked

suite "async state machines":
  setup:
    runInvoked = 0

  test "creates async state machine":
    let sm = AsyncStateMachine.new()
    check sm != nil

  test "should call run on start state":
    let sm = AsyncStateMachine.new()
    let testState = TestState.new()
    
    sm.start(testState)

    check eventually runInvoked == 1

