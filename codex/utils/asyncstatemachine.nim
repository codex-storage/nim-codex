import pkg/questionable
import pkg/chronos

type
  AsyncStateMachine* = ref object of RootObj
  AsyncState* = ref object of RootObj

method start*(stateMachine: AsyncStateMachine, initialState: AsyncState) =
  discard

