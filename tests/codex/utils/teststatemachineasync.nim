import pkg/asynctest
import pkg/chronos
import pkg/questionable
import codex/utils/statemachine

type
  AsyncMachine = ref object of StateMachineAsync
  LongRunningStart = ref object of AsyncState
  LongRunningFinish = ref object of AsyncState
  LongRunningError = ref object of AsyncState
  Callback = proc(): Future[void] {.gcsafe.}

proc triggerIn(time: Duration, cb: Callback) {.async.} =
  await sleepAsync(time)
  await cb()

method enterAsync(state: LongRunningStart) {.async.} =
  proc cb() {.async.} =
    await state.switchAsync(LongRunningFinish())
  asyncSpawn triggerIn(500.milliseconds, cb)
  await sleepAsync(1.seconds)
  await state.switchAsync(LongRunningError())

suite "async state machines":

  test "can cancel a state":
    let am = AsyncMachine()
    await am.switchAsync(LongRunningStart())
    await sleepAsync(2.seconds)
    check (am.state as LongRunningFinish).isSome
