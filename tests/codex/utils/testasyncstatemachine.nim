import std/sugar
import pkg/asynctest
import pkg/questionable
import pkg/chronos
import codex/utils/asyncstatemachine
import ../helpers/eventually

makeStateMachine(Machine, State)

type
  State1 = ref object of State
  State2 = ref object of State
  State3 = ref object of State

var runs, cancellations = [0, 0, 0]

method onMoveToNextStateEvent*(state: State): ?State {.base.} =
  discard

method run(state: State1): Future[?State] {.async.} =
  inc runs[0]
  return some State(State2.new())

method run(state: State2): Future[?State] {.async.} =
  inc runs[1]
  try:
    await sleepAsync(1.hours)
  except CancelledError:
    inc cancellations[1]

method onMoveToNextStateEvent(state: State2): ?State =
  return some State(State3.new())

method run(state: State3): Future[?State] {.async.} =
  inc runs[2]

suite "async state machines":
  var machine: Machine
  var state1, state2: State

  setup:
    runs = [0, 0, 0]
    cancellations = [0, 0, 0]
    machine = Machine.new()
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
    machine.schedule(state => state.onMoveToNextStateEvent())
    check eventually runs == [0, 1, 1]

  test "state transition will cancel the running state":
    machine.start(state2)
    machine.schedule(state => state.onMoveToNextStateEvent())
    check eventually cancellations == [0, 1, 0]
