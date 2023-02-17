import pkg/asynctest
import pkg/questionable
import pkg/chronos
import pkg/upraises
import codex/utils/asyncstatemachine
import ../helpers/eventually

type
  MyMachine = ref object of Machine
    slotsFilled: TransitionProperty[int]
    requestFinished: TransitionProperty[bool]
  State1 = ref object of State
  State2 = ref object of State
  State3 = ref object of State
  State4 = ref object of State
  State5 = ref object of State
  State6 = ref object of State

var runs, cancellations = [0, 0, 0, 0, 0]

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

method run(state: State3): Future[?State] {.async.} =
  inc runs[2]

method run(state: State4): Future[?State] {.async.} =
  inc runs[3]

method run(state: State5): Future[?State] {.async.} =
  inc runs[4]

method run(state: State6): Future[?State] {.async.} =
  raise newException(ValueError, "some error")

suite "async state machines":
  var machine: MyMachine
  var state1, state2, state3, state4, state5, state6: State

  setup:
    runs = [0, 0, 0, 0, 0]
    cancellations = [0, 0, 0, 0, 0]
    state1 = State1.new()
    state2 = State2.new()
    state3 = State3.new()
    state4 = State4.new()
    state5 = State5.new()
    state6 = State6.new()
    machine = MyMachine.new(@[
      Transition.new(
        state3,
        state4,
        proc(m: Machine, s: State): bool =
          MyMachine(m).slotsFilled.value == 2
      ),
      Transition.new(
        state4,
        state5,
        proc(m: Machine, s: State): bool =
          MyMachine(m).requestFinished.value
      ),
      Transition.new(
        state6,
        state5,
        proc(m: Machine, s: State): bool =
          MyMachine(m).errored.value
      )
    ])
    machine.slotsFilled = machine.newTransitionProperty(0)
    machine.requestFinished = machine.newTransitionProperty(false)

    # EXAMPLE USAGE ONLY -- can be removed from tests
    # should represent a typical external event callback, ie event called via
    # subscription
    proc externalEventCallback() =# would take params (rid: RequestId, slotIdx: UInt256) =
      machine.slotsFilled.setValue(1)

  test "allows no declared transitions":
    machine = MyMachine.new(@[])
    machine.start(state1)
    check eventually runs[0] == 1

  test "should call run on start state":
    machine.start(state1)
    check eventually runs[0] == 1

  test "moves to next state when run completes":
    machine.start(state1)
    check eventually runs == [1, 1, 0, 0, 0]

  test "returns current state":
    machine.start(state1)
    check eventually machine.state of State2

  test "state2 moves to state3 on event":
    machine.start(state2)
    machine.schedule(Event.transition(state2, state3))
    check eventually runs == [0, 1, 1, 0, 0]

  test "state transition will cancel the running state":
    machine.start(state2)
    machine.schedule(Event.transition(state2, state3))
    check eventually cancellations == [0, 1, 0, 0, 0]

  test "scheduled events are handled one after the other":
    machine.start(state2)
    machine.schedule(Event.transition(state2, state3))
    machine.schedule(Event.transition(state3, state1))
    check eventually runs == [1, 2, 1, 0, 0]

  test "stops scheduling and current state":
    machine.start(state2)
    await sleepAsync(1.millis)
    machine.stop()
    machine.schedule(Event.transition(state2, state3))
    await sleepAsync(1.millis)
    check runs == [0, 1, 0, 0, 0]
    check cancellations == [0, 1, 0, 0, 0]

  test "can transition to state without next state":
    machine.start(state3)
    check eventually runs == [0, 0, 1, 0, 0]
    check machine.state of State3

  test "moves states based on declared transitions and conditions":
    machine.start(state3)
    await sleepAsync(1.millis)
    machine.slotsFilled.setValue(2)
    check eventually runs == [0, 0, 1, 1, 0]

  test "moves states based on multiple declared transitions":
    machine.start(state3)
    await sleepAsync(1.millis)
    machine.slotsFilled.setValue(2) # 3 -> 4
    await sleepAsync(1.millis)
    check machine.state of State4
    machine.requestFinished.setValue(true) # 4 -> 5
    check eventually runs == [0, 0, 1, 1, 1]

  test "fails to transition when previous transition hasn't been established as running":
    machine.start(state3)
    await sleepAsync(1.millis)
    machine.slotsFilled.setValue(2)
    machine.requestFinished.setValue(true)
    check eventually runs == [0, 0, 1, 1, 1]

  test "does not move to state if trigger is false":
    machine.start(state3)
    await sleepAsync(1.millis)
    machine.slotsFilled.setValue(1)
    check eventually runs == [0, 0, 1, 0, 0]

  test "does not move to state if previous state doesn't match":
    machine.start(state4)
    await sleepAsync(1.millis)
    machine.slotsFilled.setValue(2)
    check eventually runs == [0, 0, 0, 1, 0]

  test "checks declarative transitions after current state finishes running":
    machine.start(state4)
    machine.slotsFilled.setValue(2) # on wrong starting state, so stays on state4
    await sleepAsync(1.millis)
    # manually move to State3, where the trigger and the previous state will
    # be checked
    machine.schedule(Event.transition(state4, state3))
    # state3 + trigger condition of slotsFilled == 2, should transition from
    # state 3 back to 4
    check eventually machine.state of State4

  test "captures exceptions inside of run methods":
    machine.start(state6)
    # exception throw in state6, triggered transition to state5
    check eventually machine.state of State5
    check not machine.errored.value # errored state has been cleared
    check machine.lastError.msg == "some error"
