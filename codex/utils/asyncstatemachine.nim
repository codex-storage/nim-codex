import pkg/questionable
import pkg/chronos

type
  AsyncStateMachine* = ref object of RootObj
  AsyncState* = ref object of RootObj

method run*(state: AsyncState): Future[?AsyncState] {.base.} = 
  discard

proc runState(state: AsyncState): Future[void] {.async.} =
  if next =? await state.run():
    await runState(next)

proc start*(stateMachine: AsyncStateMachine, initialState: AsyncState) =
  asyncSpawn runState(initialState)

