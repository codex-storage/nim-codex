import pkg/questionable
import pkg/chronos
import pkg/upraises

template makeStateMachine*(MachineType, StateType) =

  type
    MachineType* = ref object of RootObj
      state: StateType
      running: Future[void]
      scheduled: AsyncQueue[Event]
      scheduling: Future[void]
    StateType* = ref object of RootObj
    Event = proc(state: StateType): ?StateType {.gcsafe, upraises:[].}

  proc transition(_: type Event, previous, next: StateType): Event =
    return proc (state: StateType): ?StateType =
      if state == previous:
        return some next

  proc schedule*(machine: MachineType, event: Event) =
    machine.scheduled.putNoWait(event)

  method run*(state: StateType): Future[?StateType] {.base, upraises:[].} =
    discard

  proc run(machine: MachineType, state: StateType) {.async.} =
    if next =? await state.run():
      machine.schedule(Event.transition(state, next))

  proc scheduler(machine: MachineType) {.async.} =
    try:
      while true:
        let event = await machine.scheduled.get()
        if next =? event(machine.state):
          if not machine.running.isNil:
            await machine.running.cancelAndWait()
          machine.state = next
          machine.running = machine.run(machine.state)
    except CancelledError:
      discard

  proc start*(machine: MachineType, initialState: StateType) =
    machine.scheduling = machine.scheduler()
    machine.schedule(Event.transition(machine.state, initialState))

  proc stop*(machine: MachineType) =
    machine.scheduling.cancel()
    machine.running.cancel()

  proc new*(_: type MachineType): MachineType =
    MachineType(scheduled: newAsyncQueue[Event]())
