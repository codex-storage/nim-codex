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
import codex/conf
import ./codexclient
import ./nodes

export codexclient

export codexclient
export chronicles

logScope:
  topics = "integration testing nodes"

const workingDir = currentSourcePath() / ".." / ".." / ".." / "vendor" / "codex-contracts-eth"
when defined(windows):
  const executable = "npmstart.bat"
else:
  const executable = "npmstart.sh"

const startedOutput = "Started HTTP and WebSocket JSON-RPC server at"

type
  HardhatProcess* = ref object of NodeProcess
    logWrite: Future[void]
    logFile: ?IoHandle
    started: Future[void]

proc writeToLogFile*(node: HardhatProcess, logFilePath: string) {.async.} =
  let logFileHandle = openFile(
    logFilePath,
    {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}
  )

  without fileHandle =? logFileHandle:
    # echo "failed to open hardhat log file, path: ", logFilePath, ", error code: ", $logFileHandle.error
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
    executable,
    workingDir,
    node.arguments)

  for arg in node.arguments:
    if arg.contains "--log-file=":
      let logFilePath = arg.split("=")[1]
      node.logWrite = node.writeToLogFile(logFilePath)
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
  let node = HardhatProcess(arguments: @args)
  node.start()
  node

proc stop*(node: HardhatProcess) =
  if node.process != nil:
    node.process.terminate()
    discard node.process.waitForExit(timeout=5_000)
    node.process.close()
    node.process = nil

  if not node.logWrite.isNil and not node.logWrite.finished:
    waitFor node.logWrite.cancelAndWait()

  if logFile =? node.logFile:
    discard logFile.closeFile()

proc restart*(node: HardhatProcess) =
  node.stop()
  node.start()
  node.waitUntilStarted()

proc removeDataDir*(node: HardhatProcess) =
  discard
