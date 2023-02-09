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

var runs, cancellations = [0, 0, 0]

method onMoveToNextStateEvent*(state: TestState): ?AsyncState {.base.} =
  discard

method run(state: State1): Future[?AsyncState] {.async.} =
  inc runs[0]
  return some AsyncState(State2.new())

method run(state: State2): Future[?AsyncState] {.async.} =
  inc runs[1]
  try:
    await sleepAsync(1.hours)
  except CancelledError:
    inc cancellations[1]

method onMoveToNextStateEvent(state: State2): ?AsyncState =
  return some AsyncState(State3.new())

method run(state: State3): Future[?AsyncState] {.async.} =
  inc runs[2]

suite "async state machines":
  var machine: AsyncStateMachine
  var state1, state2: AsyncState

  setup:
    runs = [0, 0, 0]
    cancellations = [0, 0, 0]
    machine = AsyncStateMachine.new()
    state1 = State1.new()
    state2 = State2.new()

  test "should call run on start state":
    machine.start(state1)
    check eventually runs[0] == 1

  test "moves to next state when run completes":
    machine.start(state1)
    check eventually runs == [1, 1, 0]

  test "state2 moves to state3 on event":
    machine.start(state2)

    proc moveToNextStateEvent(state: AsyncState): ?AsyncState =
      TestState(state).onMoveToNextStateEvent()

    machine.schedule(Event(moveToNextStateEvent))

    check eventually runs == [0, 1, 1]

  test "state transition will cancel the running state":
    machine.start(state2)

    proc moveToNextStateEvent(state: AsyncState): ?AsyncState =
      TestState(state).onMoveToNextStateEvent()

    machine.schedule(Event(moveToNextStateEvent))

    check eventually cancellations == [0, 1, 0]
