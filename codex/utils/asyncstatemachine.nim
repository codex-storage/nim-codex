import pkg/questionable
import pkg/chronos
import pkg/chronicles
import pkg/upraises

push: {.upraises:[].}

type
  Machine* = ref object of RootObj
    state: State
    running: Future[void]
    scheduled: AsyncQueue[Event]
    scheduling: Future[void]
    started: bool
  State* = ref object of RootObj
  Event* = proc(state: State): ?State {.gcsafe, upraises:[].}

proc transition(_: type Event, previous, next: State): Event =
  return proc (state: State): ?State =
    if state == previous:
      return some next

proc schedule*(machine: Machine, event: Event) =
  if not machine.started:
    return

  try:
    machine.scheduled.putNoWait(event)
  except AsyncQueueFullError:
    raiseAssert "unlimited queue is full?!"

method run*(state: State, machine: Machine): Future[?State] {.base, async.} =
  discard

method onError*(state: State, error: ref CatchableError): ?State {.base.} =
  raise (ref Defect)(msg: "error in state machine: " & error.msg, parent: error)

proc onError(machine: Machine, error: ref CatchableError): Event =
  return proc (state: State): ?State =
    state.onError(error)

proc run(machine: Machine, state: State) {.async.} =
  try:
    if next =? await state.run(machine):
      machine.schedule(Event.transition(state, next))
  except CancelledError:
    discard

proc scheduler(machine: Machine) {.async.} =
  proc onRunComplete(udata: pointer) {.gcsafe.} =
    var fut = cast[FutureBase](udata)
    if fut.failed():
      machine.schedule(machine.onError(fut.error))

  try:
    while true:
      let event = await machine.scheduled.get()
      if next =? event(machine.state):
        if not machine.running.isNil:
          await machine.running.cancelAndWait()
        machine.state = next
        machine.running = machine.run(machine.state)
        machine.running.addCallback(onRunComplete)
  except CancelledError:
    discard

proc start*(machine: Machine, initialState: State) =
  if machine.started:
    return

  if machine.scheduled.isNil:
    machine.scheduled = newAsyncQueue[Event]()
  machine.scheduling = machine.scheduler()
  machine.started = true
  machine.schedule(Event.transition(machine.state, initialState))

proc stop*(machine: Machine) =
  if not machine.started:
    return

  if not machine.scheduling.isNil:
    machine.scheduling.cancel()
  if not machine.running.isNil:
    machine.running.cancel()

  machine.started = false
