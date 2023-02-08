import pkg/questionable
import pkg/chronos

type
  AsyncStateMachine* = ref object of RootObj
    state: AsyncState
  AsyncState* = ref object of RootObj
  Event* = proc(state: AsyncState): ?AsyncState

method run*(state: AsyncState): Future[?AsyncState] {.base.} = 
  discard

proc runState(machine: AsyncStateMachine, state: AsyncState): Future[void] {.async.} =
  machine.state = state
  if next =? await state.run():
    await machine.runState(next)

proc start*(stateMachine: AsyncStateMachine, initialState: AsyncState) =
  asyncSpawn stateMachine.runState(initialState)

proc schedule*(stateMachine: AsyncStateMachine, event: Event) =
  if next =? stateMachine.state.event():
    asyncSpawn stateMachine.runState(next)