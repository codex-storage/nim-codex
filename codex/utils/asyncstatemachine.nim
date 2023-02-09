import pkg/questionable
import pkg/chronos

template makeStateMachine*(MachineType, StateType) =

  type
    MachineType* = ref object of RootObj
      state: StateType
      running: Future[?StateType]
    StateType* = ref object of RootObj
    Event* = proc(state: StateType): ?StateType

  method run*(state: StateType): Future[?StateType] {.base.} =
    discard

  proc run*(machine: MachineType, state: StateType) {.async.} =
    if not machine.running.isNil:
      await machine.running.cancelAndWait()
    machine.state = state
    machine.running = state.run()
    if next =? await machine.running:
      await machine.run(next)

  proc start*(machine: MachineType, initialState: StateType) =
    asyncSpawn machine.run(initialState)

  proc schedule*(machine: MachineType, event: Event) =
    if next =? event(machine.state):
      asyncSpawn machine.run(next)
