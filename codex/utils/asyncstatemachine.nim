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
  State* = ref object of RootObj
  AnyState* = ref object of State
  Event* = proc(state: State): ?State {.gcsafe, upraises:[].}
  TransitionCondition* = proc(machine: Machine, state: State): bool {.gcsafe, upraises:[].}
  Transition* = object of RootObj
    prevState: State
    nextState: State
    trigger: TransitionCondition

proc new*(T: type Transition,
          prev, next: State,
          trigger: TransitionCondition): T =
  Transition(prevState: prev, nextState: next, trigger: trigger)

proc newTransitionProperty*[T](machine: Machine,
                               initialValue: T): TransitionProperty[T] =
  TransitionProperty[T](machine: machine, value: initialValue)

proc value*[T](prop: TransitionProperty[T]): T = prop.value

proc transition*(_: type Event, previous, next: State): Event =
  return proc (state: State): ?State =
    if state == previous:
      return some next

proc state*(machine: Machine): State = machine.state

proc schedule*(machine: Machine, event: Event) =
  machine.scheduled.putNoWait(event)

proc checkTransitions(machine: Machine) =
  for transition in machine.transitions:
    if transition.trigger(machine, machine.state) and
      (machine.state == nil or
       machine.state == transition.prevState or
       transition.prevState of AnyState):
      machine.schedule(Event.transition(machine.state, transition.nextState))

proc setValue*[T](prop: TransitionProperty[T], value: T) =
  prop.value = value
  prop.machine.checkTransitions()

method run*(state: State): Future[?State] {.base, upraises:[].} =
  discard

proc run(machine: Machine, state: State) {.async.} =
  try:
    if next =? await state.run():
      machine.schedule(Event.transition(state, next))
  except CancelledError:
    discard

proc scheduler(machine: Machine) {.async.} =
  proc onRunComplete(udata: pointer) {.gcsafe, raises: [Defect].} =
    var fut = cast[FutureBase](udata)
    if fut.failed():
      try:
        machine.errored.setValue(true) # triggers transitions
        machine.errored.value = false # clears error without triggering transitions
        machine.lastError = fut.error # stores error in state
      except AsyncQueueFullError as e:
        error "Cannot set transition value because queue is full", error = e

  try:
    while true:
      let event = await machine.scheduled.get()
      if next =? event(machine.state):
        if not machine.running.isNil:
          await machine.running.cancelAndWait()
        machine.state = next
        machine.running = machine.run(machine.state)
        machine.running.addCallback(onRunComplete)
      machine.checkTransitions()
  except CancelledError:
    discard

proc start*(machine: Machine, initialState: State) =
  machine.scheduling = machine.scheduler()
  machine.schedule(Event.transition(machine.state, initialState))

proc stop*(machine: Machine) =
  machine.scheduling.cancel()
  machine.running.cancel()

proc new*(T: type Machine, transitions: seq[Transition]): T =
  let m = T(
    scheduled: newAsyncQueue[Event](),
    transitions: transitions
  )
  m.errored = m.newTransitionProperty(false)
  return m
