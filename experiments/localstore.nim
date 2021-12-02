import std/os

import pkg/[chronicles, stew/byteutils, task_runner]
import pkg/[chronos/apps/http/httpcommon, chronos/apps/http/httpserver]

logScope:
  topics = "localstore"

type LocalstoreArg = ref object of ContextArg

const
  host {.strdefine.} = "127.0.0.1"
  localstore = "localstore"
  maxRequestBodySize {.intdefine.} = 10 * 1_048_576
  port {.strdefine.} = "30080"

proc localstoreContext(arg: ContextArg) {.async, gcsafe, nimcall,
  raises: [Defect].} =

  let contextArg = cast[LocalstoreArg](arg)
  discard

proc readFromStreamWriteToFile(rfd: int, destPath: string)
  {.task(kind=no_rts, stoppable=false).} =

  let reader = cast[AsyncFD](rfd).fromPipe
  var destFile = destPath.open(fmWrite)

  proc pred(data: openarray[byte]): tuple[consumed: int, done: bool]
    {.gcsafe, raises: [Defect].} =

    debug "task pred got data", byteCount=data.len

    if data.len > 0:
      try:
        discard destFile.writeBytes(data, 0, data.len)
      except Exception as e:
        debug "exception raised when task wrote to file", error=e.msg

      (data.len, data.len < 4096)

    else:
      (0, true)

  await reader.readMessage(pred)
  await reader.closeWait
  destFile.flushFile
  destFile.close

proc scheduleStop(runner: TaskRunner, s: Duration) {.async.} =
  await sleepAsync s
  await runner.stop

proc main() {.async.} =
  const destDir = currentSourcePath.parentDir.parentDir / "build" / "files"
  createDir(destDir)

  var
    localstoreArg = LocalstoreArg()
    runner = TaskRunner.new
    runnerPtr {.threadvar.}: pointer

  runnerPtr = cast[pointer](runner)

  proc process(r: RequestFence): Future[HttpResponseRef] {.async.} =
    let
      request = r.tryGet
      filename = ($request.uri).split("/")[^1]
      destPath = destDir / filename
      (rfd, wfd) = createAsyncPipe()
      writer = wfd.fromPipe

    proc pred(data: openarray[byte]): tuple[consumed: int, done: bool]
      {.gcsafe, raises: [Defect].} =

      debug "http server pred got data", byteCount=data.len

      if data.len > 0:
        try:
          # discard waitFor writer.write(@data, data.len)
          discard writer.write(@data, data.len)
        except Exception as e:
          debug "exception raised when http server wrote to task",
            error=e.msg, stacktrace=getStackTrace(e)

        (data.len, false)

      else:
        (0, true)

    asyncSpawn readFromStreamWriteToFile(runner, localstore, rfd.int, destPath)
    await request.getBodyReader.tryGet.readMessage(pred)
    await writer.closeWait
    discard request.respond(Http200)

  let
    address = initTAddress(host & ":" & port)
    socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
    server = HttpServerRef.new(address, process,
      socketFlags = socketFlags, maxRequestBodySize = maxRequestBodySize).tryGet

  var serverPtr {.threadvar.}: pointer
  serverPtr = cast[pointer](server)

  proc stop() {.noconv.} =
    waitFor cast[HttpServerRef](serverPtr).stop
    waitFor cast[TaskRunner](runnerPtr).stop

  setControlCHook(stop)

  runner.createWorker(pool, localstore, localstoreContext, localstoreArg, 8)
  runner.workers[localstore].worker.awaitTasks = false
  await runner.start
  server.start
  asyncSpawn runner.scheduleStop(10.seconds)

  while runner.running.load: poll()

when isMainModule:
  waitFor main()
  quit QuitSuccess
