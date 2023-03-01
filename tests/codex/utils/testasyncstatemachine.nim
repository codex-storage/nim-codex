import pkg/asynctest
import pkg/questionable
import pkg/chronos
import pkg/upraises
import codex/utils/asyncstatemachine
import ../helpers/eventually

type
  State1 = ref object of State
  State2 = ref object of State
  State3 = ref object of State

var runs, cancellations = [0, 0, 0]

method onMoveToNextStateEvent*(state: State): ?State {.base, upraises:[].} =
  discard

method run(state: State1, machine: Machine): Future[?State] {.async.} =
  inc runs[0]
  return some State(State2.new())

method run(state: State2, machine: Machine): Future[?State] {.async.} =
  inc runs[1]
  try:
    await sleepAsync(1.hours)
  except CancelledError:
    inc cancellations[1]
    raise

method onMoveToNextStateEvent(state: State2): ?State =
  some State(State3.new())

method run(state: State3, machine: Machine): Future[?State] {.async.} =
  inc runs[2]

method onMoveToNextStateEvent(state: State3): ?State =
  some State(State1.new())

suite "async state machines":
  var machine: Machine
  var state1, state2: State

  proc moveToNextStateEvent(state: State): ?State =
    state.onMoveToNextStateEvent()

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
    machine.schedule(moveToNextStateEvent)
    check eventually runs == [0, 1, 1]

  test "state transition will cancel the running state":
    machine.start(state2)
    machine.schedule(moveToNextStateEvent)
    check eventually cancellations == [0, 1, 0]

  test "scheduled events are handled one after the other":
    machine.start(state2)
    machine.schedule(moveToNextStateEvent)
    machine.schedule(moveToNextStateEvent)
    check eventually runs == [1, 2, 1]

  test "stops scheduling and current state":
    machine.start(state2)
    await sleepAsync(1.millis)
    machine.stop()
    machine.schedule(moveToNextStateEvent)
    await sleepAsync(1.millis)
    check runs == [0, 1, 0]
    check cancellations == [0, 1, 0]

type
  MyMachine = ref object of Machine
  State4 = ref object of State
  State5 = ref object of State
  ErrorState = ref object of State
    error: ref CatchableError
  MyMachineError = object of CatchableError

var errorRuns = 0
var onErrorCalled, onErrorOverridden = false

proc raiseMyMachineError() =
  raise newException(MyMachineError, "some error")

method run*(state: State4, machine: Machine): Future[?State] {.async.} =
  raiseMyMachineError()

method run*(state: State5, machine: Machine): Future[?State] {.async.} =
  raiseMyMachineError()

method run(state: ErrorState, machine: Machine): Future[?State] {.async.} =
  check not state.error.isNil
  check state.error of MyMachineError
  check state.error.msg == "some error"
  inc errorRuns

method onError*(state: State, error: ref CatchableError): ?State {.base, upraises:[].} =
  return some State(ErrorState(error: error))

method onError*(state: State5, error: ref CatchableError): ?State {.upraises:[].} =
  onErrorOverridden = true

method onError*(machine: MyMachine, error: ref CatchableError): Event =
  onErrorCalled = true
  return proc (state: State): ?State =
    state.onError(error)

suite "async state machines - errors":
  var machine: MyMachine
  var state4, state5: State

  setup:
    errorRuns = 0
    machine = MyMachine.new()
    state4 = State4.new()
    state5 = State5.new()
    onErrorCalled = false
    onErrorOverridden = false

  test "catches errors in run":
    machine.start(state4)
    check eventually onErrorCalled

  test "errors in run can be handled at the base state level":
    machine.start(state4)
    check eventually errorRuns == 1

  test "errors in run can be handled by overridden onError at the state level":
    machine.start(state5)
    check eventually onErrorOverridden

