import std/typetraits # DELETE ME
import std/sequtils
import std/tables
import pkg/questionable
import pkg/chronos
import pkg/chronicles
import pkg/upraises

logScope:
  topics = "codex async state machine"

type
  TransitionProperty*[T] = ref object of RootObj
    machine: Machine
    value: T
  Machine* = ref object of RootObj
    state: State
    running: Future[void]
    scheduled: AsyncQueue[Event]
    scheduling: Future[void]
    transitions: seq[Transition]
    errored*: TransitionProperty[bool]
    lastError*: ref CatchableError
    states: Table[int, State]
    started: bool
  State* = ref object of RootObj
  AnyState* = ref object of State
  Event* = proc(state: State): ?State {.gcsafe, upraises:[].}
  TransitionCondition* = proc(machine: Machine, state: State): bool {.gcsafe, upraises:[].}
  Transition* = object of RootObj
    prevStates: seq[State]
    nextState: State
    trigger: TransitionCondition

proc new*(T: type Transition,
          prev: openArray[State],
          next: State,
          trigger: TransitionCondition): T =
  Transition(prevStates: prev.toSeq, nextState: next, trigger: trigger)

proc new*(T: type Transition,
          prev, next: State,
          trigger: TransitionCondition): T =
  Transition.new([prev], next, trigger)

proc newTransitionProperty*[T](machine: Machine,
                               initialValue: T): TransitionProperty[T] =
  TransitionProperty[T](machine: machine, value: initialValue)

proc value*[T](prop: TransitionProperty[T]): T = prop.value

proc transition*(_: type Event, previous, next: State): Event =
  return proc (state: State): ?State =
    if state == previous:
      return some next

method `$`*(state: State): string {.base.} = "Base state"

proc state*(machine: Machine): State = machine.state

template getState*(machine: Machine, id: untyped): State =
  machine.states[id.int]

proc addState*(machine: Machine, states: varargs[(int, State)]) =
  machine.states = states.toTable

proc schedule*(machine: Machine, event: Event) =
  machine.scheduled.putNoWait(event)

proc checkTransitions(machine: Machine) =
  if not machine.started:
    return

  for transition in machine.transitions:
    if transition.trigger(machine, machine.state) and
      machine.state != transition.nextState and # avoid transitioning to self
      (machine.state == nil or
       machine.state in transition.prevStates or # state instance, multiple
       transition.prevStates.any(proc (s: State): bool = s of AnyState)):
      # echo "scheduling transition from ", machine.state, " to ", transition.nextState
      machine.schedule(Event.transition(machine.state, transition.nextState))
      return

proc setValue*[T](prop: TransitionProperty[T], value: T) =
  prop.value = value
  prop.machine.checkTransitions()

proc setError*(machine: Machine, error: ref CatchableError) =
  machine.errored.setValue(true) # triggers transitions
  machine.errored.value = false # clears error without triggering transitions
  machine.lastError = error # stores error in state

method run*(state: State, machine: Machine): Future[?State] {.base, upraises:[].} =
  discard

proc run(machine: Machine, state: State) {.async.} =
  try:
    if next =? await state.run(machine):
      machine.schedule(Event.transition(state, next))
  except CancelledError:
    discard

proc scheduler(machine: Machine) {.async.} =
  proc onRunComplete(udata: pointer) {.gcsafe, raises: [Defect].} =
    var fut = cast[FutureBase](udata)
    if fut.failed():
      try:
        machine.setError(fut.error)
      except AsyncQueueFullError as e:
        error "Cannot set transition value because queue is full", error = e.msg

  try:
    while true:
      let event = await machine.scheduled.get()
      if next =? event(machine.state):
        if not machine.running.isNil:
          # echo "cancelling current state: ", machine.state
          await machine.running.cancelAndWait()
        # echo "transitioning from ", $ machine.state, " to ", $ next
        # echo "moving from ", if machine.state.isNil: "nil" else: $machine.state, " to ", next
        machine.state = next
        # trace "running state", state = machine.state
        machine.running = machine.run(machine.state)
        machine.running.addCallback(onRunComplete)
        machine.checkTransitions()
  except CancelledError:
    discard

proc start*(machine: Machine, initialState: State) =
  machine.scheduling = machine.scheduler()
  machine.schedule(Event.transition(machine.state, initialState))
  machine.started = true

proc stop*(machine: Machine) =
  if not machine.running.isNil and not machine.running.finished:
    machine.scheduling.cancel()
  if not machine.running.isNil and not machine.running.finished:
    machine.running.cancel()
  machine.started = false

proc new*(T: type Machine, transitions: seq[Transition]): T =
  let m = T(
    scheduled: newAsyncQueue[Event](),
    transitions: transitions
  )
  m.errored = m.newTransitionProperty(false)
  return m
