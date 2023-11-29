import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/libp2p
import pkg/stew/byteutils
import std/osproc
import std/os
import std/sequtils
import std/streams
import std/strutils
import codex/conf
import codex/utils/exceptions
import codex/utils/trackedfutures
import ./codexclient

export codexclient
export chronicles

logScope:
  topics = "integration testing node process"

type
  NodeProcess* = ref object of RootObj
    process*: AsyncProcessRef
    arguments*: seq[string]
    debug: bool
    trackedFutures*: TrackedFutures
    name*: string

method workingDir(node: NodeProcess): string {.base.} =
  raiseAssert "[workingDir] not implemented"

method executable(node: NodeProcess): string {.base.} =
  raiseAssert "[executable] not implemented"

method startedOutput(node: NodeProcess): string {.base.} =
  raiseAssert "[startedOutput] not implemented"

method processOptions(node: NodeProcess): set[AsyncProcessOption] {.base.} =
  raiseAssert "[processOptions] not implemented"

method onOutputLineCaptured(node: NodeProcess, line: string) {.base.} =
  raiseAssert "[onOutputLineCaptured] not implemented"

method start(node: NodeProcess) {.base, async.} =
  logScope:
    nodeName = node.name

  trace "starting node", args = node.arguments

  node.process = await startProcess(
    node.executable,
    node.workingDir,
    node.arguments,
    options = node.processOptions,
    stdoutHandle = AsyncProcess.Pipe
  )

proc captureOutput*(
  node: NodeProcess,
  output: string,
  started: Future[void]
) {.async.} =

  logScope:
    nodeName = node.name

  trace "waiting for output", output

  let stream = node.process.stdOutStream

  try:
    while(let line = await stream.readLine(0, "\n"); line != ""):
      if node.debug:
        # would be nice if chronicles could parse and display with colors
        echo line

      if not started.isNil and not started.finished and line.contains(output):
        started.complete()

      node.onOutputLineCaptured(line)

      await sleepAsync(1.millis)
  except AsyncStreamReadError as e:
    error "error reading output stream", error = e.msgDetail

proc startNode*[T: NodeProcess](
  _: type T,
  args: seq[string],
  debug: string | bool = false,
  name: string
): Future[T] {.async.} =

  ## Starts a Codex Node with the specified arguments.
  ## Set debug to 'true' to see output of the node.
  let node = T(
    arguments: @args,
    debug: ($debug != "false"),
    trackedFutures: TrackedFutures.new(),
    name: name
  )
  await node.start()
  return node

method stop*(node: NodeProcess) {.base, async.} =
  logScope:
    nodeName = node.name

  await node.trackedFutures.cancelTracked()
  if node.process != nil:
    try:
      if err =? node.process.terminate().errorOption:
        error "failed to terminate node process", errorCode = err
      discard await node.process.waitForExit(timeout=5.seconds)
      # close process' streams
      await node.process.closeWait()

    except AsyncTimeoutError as e:
      error "waiting for process exit timed out", error = e.msgDetail
    except CatchableError as e:
      error "error stopping node process", error = e.msg
    finally:
      node.process = nil
    trace "node stopped"

proc waitUntilStarted*(node: NodeProcess) {.async.} =
  logScope:
    nodeName = node.name

  trace "waiting until node started"

  let started = newFuture[void]()
  try:
    discard node.captureOutput(node.startedOutput, started).track(node)
    await started.wait(5.seconds)
  except AsyncTimeoutError as e:
    # attempt graceful shutdown in case node was partially started, prevent
    # zombies
    await node.stop()
    raiseAssert "node did not output '" & node.startedOutput & "'"

proc restart*(node: NodeProcess) {.async.} =
  await node.stop()
  await node.start()
  await node.waitUntilStarted()

method removeDataDir*(node: NodeProcess) {.base.} =
  raiseAssert "[removeDataDir] not implemented"
