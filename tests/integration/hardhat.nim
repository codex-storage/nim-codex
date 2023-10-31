import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/stew/io2
import std/osproc
import std/os
import std/streams
import std/strutils
import pkg/codex/conf
import pkg/codex/utils/trackedfutures
import ./codexclient
import ./nodes

export codexclient

export codexclient
export chronicles

logScope:
  topics = "integration testing nodes"

const workingDir = currentSourcePath() / ".." / ".." / ".." / "vendor" / "codex-contracts-eth"
const startedOutput = "Started HTTP and WebSocket JSON-RPC server at"

type
  HardhatProcess* = ref object of NodeProcess
    logFile: ?IoHandle
    started: Future[void]
    trackedFutures: TrackedFutures

proc captureOutput*(node: HardhatProcess, logFilePath: string) {.async.} =
  let logFileHandle = openFile(
    logFilePath,
    {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}
  )

  without fileHandle =? logFileHandle:
    error "failed to open log file",
      path = logFilePath,
      errorCode = $logFileHandle.error

  node.logFile = some fileHandle
  node.started = newFuture[void]("hardhat.started")
  try:
    for line in node.process.outputStream.lines:

      if line.contains(startedOutput):
        node.started.complete()

      if error =? fileHandle.writeFile(line & "\n").errorOption:
        error "failed to write to hardhat file", errorCode = error
        discard fileHandle.closeFile()
        return

      await sleepAsync(1.millis)

  except CancelledError:
    discard

proc start(node: HardhatProcess) =
  node.process = osproc.startProcess(
    "npm start",
    workingDir,
    # node.arguments,
    options={poEvalCommand})

  for arg in node.arguments:
    if arg.contains "--log-file=":
      let logFilePath = arg.split("=")[1]
      discard node.captureOutput(logFilePath).track(node)
      break

proc waitUntilOutput*(node: HardhatProcess, output: string) =
  if not node.started.isNil:
    try:
      waitFor node.started.wait(5000.milliseconds)
      return
    except AsyncTimeoutError:
      discard # should raiseAssert below
  else:
    for line in node.process.outputStream.lines:
      if line.contains(output):
        return
  raiseAssert "node did not output '" & output & "'"

proc waitUntilStarted*(node: HardhatProcess) =
  node.waitUntilOutput(startedOutput)

proc startHardhatProcess*(args: openArray[string]): HardhatProcess =
  ## Starts a Hardhat Node with the specified arguments.
  let node = HardhatProcess(arguments: @args, trackedFutures: TrackedFutures.new())
  node.start()
  node

method stop*(node: HardhatProcess) =
  # terminate the process
  procCall NodeProcess(node).stop()

  waitFor node.trackedFutures.cancelTracked()

  if logFile =? node.logFile:
    discard logFile.closeFile()

proc restart*(node: HardhatProcess) =
  node.stop()
  node.start()
  node.waitUntilStarted()

proc removeDataDir*(node: HardhatProcess) =
  discard
