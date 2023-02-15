import pkg/questionable
import pkg/chronos
import pkg/upraises

type
  Machine* = ref object of RootObj
    state: State
    running: Future[void]
    scheduled: AsyncQueue[Event]
    scheduling: Future[void]
    transitions: seq[Transition]
  State* = ref object of RootObj
  Event = proc(state: State): ?State {.gcsafe, upraises:[].}
  TransitionCondition* = proc(machine: Machine, state: State): bool {.gcsafe, upraises:[].}
  Transition* = object of RootObj
    prevState: State
    nextState: State
    trigger: TransitionCondition
  TransitionProperty*[T] = ref object of RootObj
    machine: Machine
    value*: T

proc new*(T: type Transition,
          prev, next: State,
          trigger: TransitionCondition): T =
  Transition(prevState: prev, nextState: next, trigger: trigger)

proc newTransitionProperty*[T](self: Machine,
                               initialValue: T): TransitionProperty[T] =
  TransitionProperty[T](machine: self, value: initialValue)

proc transition(_: type Event, previous, next: State): Event =
  return proc (state: State): ?State =
    if state == previous:
      return some next

proc setValue*[T](prop: TransitionProperty[T], value: T) =
  prop.value = value
  let machine = prop.machine
  for transition in machine.transitions:
    if transition.trigger(machine, machine.state) and
      (machine.state == nil or machine.state == transition.prevState):
      machine.schedule(Event.transition(machine.state, transition.nextState))

proc schedule*(machine: Machine, event: Event) =
  machine.scheduled.putNoWait(event)

method run*(state: State): Future[?State] {.base, upraises:[].} =
  discard

proc run(machine: Machine, state: State) {.async.} =
  try:
    if next =? await state.run():
      machine.schedule(Event.transition(state, next))
  except CancelledError:
    discard

proc scheduler(machine: Machine) {.async.} =
  try:
    while true:
      let event = await machine.scheduled.get()
      if next =? event(machine.state):
        if not machine.running.isNil:
          await machine.running.cancelAndWait()
        machine.state = next
        machine.running = machine.run(machine.state)
        asyncSpawn machine.running
  except CancelledError:
    discard

proc start*(machine: Machine, initialState: State) =
  machine.scheduling = machine.scheduler()
  machine.schedule(Event.transition(machine.state, initialState))

proc stop*(machine: Machine) =
  machine.scheduling.cancel()
  machine.running.cancel()

proc new*(T: type Machine, transitions: seq[Transition]): T =
  T(scheduled: newAsyncQueue[Event](), transitions: transitions)
