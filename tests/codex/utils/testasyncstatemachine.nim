import pkg/asynctest
import pkg/questionable
import pkg/chronos
import pkg/upraises
import codex/utils/asyncstatemachine
import ../helpers/eventually

type
  MyMachine = ref object of Machine
    slotFilled: TransitionProperty[bool]
  State1 = ref object of State
  State2 = ref object of State
  State3 = ref object of State

var runs, cancellations = [0, 0, 0]

method onMoveToNextStateEvent*(state: State): ?State {.base, upraises:[].} =
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
    raise

method onMoveToNextStateEvent(state: State2): ?State =
  some State(State3.new())

method run(state: State3): Future[?State] {.async.} =
  inc runs[2]

method onMoveToNextStateEvent(state: State3): ?State =
  some State(State1.new())

suite "async state machines":
  var machine: MyMachine
  var state1, state2, state3: State

  proc moveToNextStateEvent(state: State): ?State =
    state.onMoveToNextStateEvent()

  setup:
    runs = [0, 0, 0]
    cancellations = [0, 0, 0]
    state1 = State1.new()
    state2 = State2.new()
    state3 = State3.new()
    machine = MyMachine.new(@[
      Transition.new(
        state3,
        state1,
        proc(m: Machine, s: State): bool =
          MyMachine(m).slotFilled.value
      )
    ])
    machine.slotFilled = machine.newTransitionProperty(false)

    # EXAMPLE USAGE ONLY -- can be removed from tests
    # should represent a typical external event callback, ie event called via
    # subscription
    proc externalEventCallback() =# would take params (rid: RequestId, slotIdx: UInt256) =
      machine.slotFilled.setValue(true)

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

  test "can transition to state without next state":
    machine.start(state3)
    check eventually runs == [0, 0, 1]

  test "moves states based on declared transitions and conditions":
    machine.start(state3)
    machine.slotFilled.setValue(true)
    check eventually runs == [1, 0, 1]
