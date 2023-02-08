import pkg/questionable
import pkg/chronos

type
  AsyncStateMachine* = ref object of RootObj
    state: AsyncState
    running: Future[?AsyncState]
  AsyncState* = ref object of RootObj
  Event* = proc(state: AsyncState): ?AsyncState

method run*(state: AsyncState): Future[?AsyncState] {.base.} = 
  discard

proc runState(machine: AsyncStateMachine, state: AsyncState): Future[void] {.async.} =
  if not machine.running.isNil:
    await machine.running.cancelAndWait()
  machine.state = state
  machine.running = state.run()
  if next =? await machine.running:
    await machine.runState(next)

proc start*(stateMachine: AsyncStateMachine, initialState: AsyncState) =
  asyncSpawn stateMachine.runState(initialState)

proc schedule*(stateMachine: AsyncStateMachine, event: Event) =
  if next =? stateMachine.state.event():
    asyncSpawn stateMachine.runState(next)