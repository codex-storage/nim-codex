import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos/asyncproc
import pkg/libp2p
import std/os
import std/strformat
import std/strutils
import codex/conf
import codex/utils/exceptions
import codex/utils/trackedfutures
import ./codexclient

export codexclient
export chronicles

{.push raises: [].}

logScope:
  topics = "integration testing node process"

type
  NodeProcess* = ref object of RootObj
    process*: AsyncProcessRef
    arguments*: seq[string]
    debug: bool
    trackedFutures*: TrackedFutures
    name*: string

  NodeProcessError* = object of CatchableError

method workingDir(node: NodeProcess): string {.base, gcsafe.} =
  raiseAssert "not implemented"

method executable(node: NodeProcess): string {.base, gcsafe.} =
  raiseAssert "not implemented"

method startedOutput(node: NodeProcess): string {.base, gcsafe.} =
  raiseAssert "not implemented"

method processOptions(node: NodeProcess): set[AsyncProcessOption] {.base, gcsafe.} =
  raiseAssert "not implemented"

method outputLineEndings(node: NodeProcess): string {.base, gcsafe.} =
  raiseAssert "not implemented"

method onOutputLineCaptured(node: NodeProcess, line: string) {.base, gcsafe.} =
  raiseAssert "not implemented"

method start*(node: NodeProcess) {.base, async: (raises: [CancelledError]).} =
  logScope:
    nodeName = node.name

  let poptions = node.processOptions + {AsyncProcessOption.StdErrToStdOut}
  trace "starting node",
    args = node.arguments, executable = node.executable, workingDir = node.workingDir

  try:
    if node.debug:
      echo "starting codex node with args: ", node.arguments.join(" ")
    node.process = await startProcess(
      node.executable,
      node.workingDir,
      node.arguments,
      options = poptions,
      stdoutHandle = AsyncProcess.Pipe,
    )
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "failed to start node process", error = e.msg

proc captureOutput(
    node: NodeProcess, output: string, started: Future[void]
) {.async: (raises: []).} =
  logScope:
    nodeName = node.name

  trace "waiting for output", output

  try:
    while node.process.running.option == some true:
      while (
        let line = await node.process.stdoutStream.readLine(0, node.outputLineEndings)
        line != ""
      )
      :
        if node.debug:
          # would be nice if chronicles could parse and display with colors
          echo line

        if not started.isNil and not started.finished and line.contains(output):
          started.complete()

        node.onOutputLineCaptured(line)

        await sleepAsync(1.nanos)
      await sleepAsync(1.nanos)
  except CancelledError:
    discard # do not propagate as captureOutput was asyncSpawned
  except AsyncStreamError as e:
    error "error reading output stream", error = e.msgDetail

proc startNode*[T: NodeProcess](
    _: type T, args: seq[string], debug: string | bool = false, name: string
): Future[T] {.async: (raises: [CancelledError]).} =
  ## Starts a Codex Node with the specified arguments.
  ## Set debug to 'true' to see output of the node.
  let node = T(
    arguments: @args,
    debug: ($debug != "false"),
    trackedFutures: TrackedFutures.new(),
    name: name,
  )
  await node.start()
  return node

method stop*(
    node: NodeProcess, expectedErrCode: int = -1
) {.base, async: (raises: []).} =
  logScope:
    nodeName = node.name

  await node.trackedFutures.cancelTracked()
  if not node.process.isNil:
    let processId = node.process.processId
    trace "terminating node process...", processId
    try:
      let exitCode = await noCancel node.process.terminateAndWaitForExit(2.seconds)
      if exitCode > 0 and exitCode != 143 and # 143 = SIGTERM (initiated above)
      exitCode != expectedErrCode:
        warn "process exited with a non-zero exit code", exitCode
      trace "node process terminated", exitCode
    except CatchableError:
      try:
        let forcedExitCode = await noCancel node.process.killAndWaitForExit(3.seconds)
        trace "node process forcibly killed with exit code: ", exitCode = forcedExitCode
      except CatchableError as e:
        warn "failed to kill node process in time, it will be killed when the parent process exits",
          error = e.msg
        writeStackTrace()

      trace "node stopped"

proc waitUntilOutput*(
    node: NodeProcess, output: string
) {.async: (raises: [CancelledError, AsyncTimeoutError]).} =
  logScope:
    nodeName = node.name

  trace "waiting until", output

  let started = newFuture[void]()
  let fut = node.captureOutput(output, started)
  node.trackedFutures.track(fut)
  asyncSpawn fut
  try:
    await started.wait(60.seconds) # allow enough time for proof generation
  except AsyncTimeoutError as e:
    raise e
  except CancelledError as e:
    raise e
  except CatchableError as e: # unsure where this originates from
    error "unexpected error occurred waiting for node output", error = e.msg

proc waitUntilStarted*(
    node: NodeProcess
) {.async: (raises: [CancelledError, NodeProcessError]).} =
  logScope:
    nodeName = node.name

  try:
    await node.waitUntilOutput(node.startedOutput)
    trace "node started"
  except AsyncTimeoutError:
    # attempt graceful shutdown in case node was partially started, prevent
    # zombies
    await node.stop()
    # raise error here so that all nodes (not just this one) can be
    # shutdown gracefully
    raise
      newException(NodeProcessError, "node did not output '" & node.startedOutput & "'")

method restart*(node: NodeProcess) {.base, async.} =
  await node.stop()
  await node.start()
  await node.waitUntilStarted()

method removeDataDir*(node: NodeProcess) {.base, raises: [NodeProcessError].} =
  raiseAssert "[removeDataDir] not implemented"
