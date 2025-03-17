import pkg/questionable
import pkg/chronos
import ../logutils
import ./trackedfutures
import ./exceptions

{.push raises: [].}

type
  Machine* = ref object of RootObj
    state: State
    running: Future[void]
    scheduled: AsyncQueue[Event]
    started: bool
    trackedFutures: TrackedFutures

  State* = ref object of RootObj
  Query*[T] = proc(state: State): T
  Event* = proc(state: State): ?State {.gcsafe, raises: [].}

logScope:
  topics = "statemachine"

proc new*[T: Machine](_: type T): T =
  T(trackedFutures: TrackedFutures.new())

method `$`*(state: State): string {.base, gcsafe.} =
  raiseAssert "not implemented"

proc transition(_: type Event, previous, next: State): Event =
  return proc(state: State): ?State =
    if state == previous:
      return some next

proc query*[T](machine: Machine, query: Query[T]): ?T =
  if machine.state.isNil:
    none T
  else:
    some query(machine.state)

proc schedule*(machine: Machine, event: Event) =
  if not machine.started:
    return

  try:
    machine.scheduled.putNoWait(event)
  except AsyncQueueFullError:
    raiseAssert "unlimited queue is full?!"

method run*(
    state: State, machine: Machine
): Future[?State] {.base, async: (raises: []).} =
  discard

proc run(machine: Machine, state: State) {.async: (raises: []).} =
  if next =? await state.run(machine):
    machine.schedule(Event.transition(state, next))

proc scheduler(machine: Machine) {.async: (raises: []).} =
  var running: Future[void].Raising([])
  while machine.started:
    try:
      let event = await machine.scheduled.get()
      if next =? event(machine.state):
        if not running.isNil and not running.finished:
          trace "cancelling current state", state = $machine.state
          await running.cancelAndWait()
        let fromState =
          if machine.state.isNil:
            "<none>"
          else:
            $machine.state
        machine.state = next
        debug "enter state", state = fromState & " => " & $machine.state
        running = machine.run(machine.state)
        machine.trackedFutures.track(running)
    except CancelledError:
      break # do not propagate bc it is asyncSpawned

proc start*(machine: Machine, initialState: State) =
  if machine.started:
    return

  if machine.scheduled.isNil:
    machine.scheduled = newAsyncQueue[Event]()

  machine.started = true
  let fut = machine.scheduler()
  machine.trackedFutures.track(fut)
  machine.schedule(Event.transition(machine.state, initialState))

proc stop*(machine: Machine) {.async.} =
  if not machine.started:
    return

  trace "stopping state machine"

  machine.started = false
  await machine.trackedFutures.cancelTracked()

  machine.state = nil
