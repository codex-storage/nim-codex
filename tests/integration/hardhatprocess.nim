import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos
import pkg/stew/io2
import std/osproc
import std/os
import std/sets
import std/streams
import std/strutils
import std/sugar
import pkg/codex/conf
import pkg/codex/utils/trackedfutures
import ./codexclient
import ./nodeprocess

export codexclient
export chronicles

logScope:
  topics = "integration testing hardhat process"
  nodeName = "hardhat"

type
  HardhatProcess* = ref object of NodeProcess
    logFile: ?IoHandle

method workingDir(node: HardhatProcess): string =
  return currentSourcePath() / ".." / ".." / ".." / "vendor" / "codex-contracts-eth"

method executable(node: HardhatProcess): string =
  return "npm start"

method startedOutput(node: HardhatProcess): string =
  return "Started HTTP and WebSocket JSON-RPC server at"

method processOptions(node: HardhatProcess): set[AsyncProcessOption] =
  return {AsyncProcessOption.EvalCommand, AsyncProcessOption.StdErrToStdOut}

proc openLogFile(node: HardhatProcess, logFilePath: string): IoHandle =
  let logFileHandle = openFile(
    logFilePath,
    {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}
  )

  without fileHandle =? logFileHandle:
    fatal "failed to open log file",
      path = logFilePath,
      errorCode = $logFileHandle.error

    raiseAssert "failed to open log file, aborting"

  return fileHandle

proc startNode*(
  _: type HardhatProcess,
  args: seq[string] = @[],
  debug: string | bool = false,
  name: string = "hardhat"
): Future[HardhatProcess] {.async.} =

  var logFilePath = ""

  var arguments = newSeq[string]()
  for arg in args:
    if arg.contains "--log-file=":
      logFilePath = arg.split("=")[1]
    else:
      arguments.add arg

  trace "starting hardhat node", arguments
  echo ">>> starting hardhat node with args: ", arguments
  let node = await NodeProcess.startNode(arguments, debug, "hardhat")
  let hardhat = HardhatProcess(node)

  if logFilePath != "":
    hardhat.logFile = some hardhat.openLogFile(logFilePath)

  # let hardhat = HardhatProcess()
  return hardhat

method onOutputLineCaptured(node: HardhatProcess, line: string) =
  without logFile =? node.logFile:
    return

  if error =? logFile.writeFile(line & "\n").errorOption:
    error "failed to write to hardhat file", errorCode = error
    discard logFile.closeFile()
    node.logFile = none IoHandle

method stop*(node: HardhatProcess) {.async.} =
  # terminate the process
  procCall NodeProcess(node).stop()

  if logFile =? node.logFile:
    discard logFile.closeFile()

method removeDataDir*(node: HardhatProcess) =
  discard
