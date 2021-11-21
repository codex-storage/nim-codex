import std/os

import pkg/[chronicles, stew/byteutils, task_runner]

logScope:
  topics = "localstore"

type LocalstoreArg = ref object of ContextArg

const localstore = "localstore"

proc localstoreContext(arg: ContextArg) {.async, gcsafe, nimcall,
  raises: [Defect].} =

  let contextArg = cast[LocalstoreArg](arg)
  discard

proc readFromStreamWriteToFile(rfd: int, destFilePath: string)
  {.task(kind=no_rts, stoppable=false).} =

  let task = taskArg.taskName

  let reader = cast[AsyncFD](rfd).fromPipe
  var destFile = destFilePath.open(fmWrite)

  while workerRunning[].load:
    let data = await reader.read(12)
    discard destFile.writeBytes(data, 0, 12)

  destFile.close

proc runTasks(runner: TaskRunner) {.async.} =
  let (rfd, wfd) = createAsyncPipe()
  asyncSpawn readFromStreamWriteToFile(runner, localstore, rfd.int,
    currentSourcePath.parentDir / "foo.txt")

  let writer = wfd.fromPipe
  while runner.running.load:
    let n = await writer.write("hello there ".toBytes)
    await sleepAsync 10.milliseconds

proc scheduleStop(runner: TaskRunner, s: Duration) {.async.} =
  await sleepAsync 10.seconds
  await runner.stop

proc main() {.async.} =
  var
    localstoreArg = LocalstoreArg()
    runner = TaskRunner.new
    runnerPtr {.threadvar.}: pointer

  runnerPtr = cast[pointer](runner)
  proc stop() {.noconv.} = waitFor cast[TaskRunner](runnerPtr).stop
  setControlCHook(stop)

  runner.createWorker(thread, localstore, localstoreContext, localstoreArg)
  await runner.start
  asyncSpawn runner.runTasks
  asyncSpawn runner.scheduleStop(10.seconds)

  while runner.running.load: poll()

when isMainModule:
  waitFor main()
  quit QuitSuccess
