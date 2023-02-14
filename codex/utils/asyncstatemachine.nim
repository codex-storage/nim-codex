import pkg/questionable
import pkg/chronos
import pkg/upraises

type
  Machine* = ref object of RootObj
    state: State
    running: Future[void]
    scheduled: AsyncQueue[Event]
    scheduling: Future[void]
  State* = ref object of RootObj
  Event = proc(state: State): ?State {.gcsafe, upraises:[].}

proc transition(_: type Event, previous, next: State): Event =
  return proc (state: State): ?State =
    if state == previous:
      return some next

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

proc new*(_: type Machine): Machine =
  Machine(scheduled: newAsyncQueue[Event]())
