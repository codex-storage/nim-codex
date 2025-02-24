import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos
import pkg/chronos/asyncproc
import pkg/stew/io2
import std/os
import std/sets
import std/sequtils
import std/strformat
import std/strutils
import pkg/codex/conf
import pkg/codex/utils/trackedfutures
import ./codexclient
import ./nodeprocess

export codexclient
export chronicles
export nodeprocess

{.push raises: [].}

logScope:
  topics = "integration testing hardhat process"

type
  OnOutputLineCaptured = proc(line: string) {.gcsafe, raises: [].}
  HardhatProcess* = ref object of NodeProcess
    logFile: ?IoHandle
    onOutputLine: OnOutputLineCaptured

  HardhatProcessError* = object of NodeProcessError

method workingDir(node: HardhatProcess): string =
  return currentSourcePath() / ".." / ".." / ".." / "vendor" / "codex-contracts-eth"

method executable(node: HardhatProcess): string =
  return
    "node_modules" / ".bin" / (when defined(windows): "hardhat.cmd" else: "hardhat")

method startedOutput(node: HardhatProcess): string =
  return "Started HTTP and WebSocket JSON-RPC server at"

method processOptions(node: HardhatProcess): set[AsyncProcessOption] =
  return {}

method outputLineEndings(node: HardhatProcess): string =
  return "\n"

proc openLogFile(node: HardhatProcess, logFilePath: string): IoHandle =
  let logFileHandle =
    openFile(logFilePath, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate})

  without fileHandle =? logFileHandle:
    fatal "failed to open log file",
      path = logFilePath, errorCode = $logFileHandle.error

    raiseAssert "failed to open log file, aborting"

  return fileHandle

method start*(
    node: HardhatProcess
) {.async: (raises: [CancelledError, NodeProcessError]).} =
  logScope:
    nodeName = node.name

  var executable = ""
  try:
    executable = absolutePath(node.workingDir / node.executable)
    if not fileExists(executable):
      raiseAssert "cannot start hardhat, executable doesn't exist (looking for " &
        &"{executable}). Try running `npm install` in {node.workingDir}."
  except CatchableError as parent:
    raiseAssert "failed build path to hardhat executable: " & parent.msg

  let poptions = node.processOptions + {AsyncProcessOption.StdErrToStdOut}
  let args = @["node", "--export", "deployment-localhost.json"].concat(node.arguments)
  trace "starting node",
    args, executable, workingDir = node.workingDir, processOptions = poptions

  try:
    node.process = await startProcess(
      executable,
      node.workingDir,
      args,
      options = poptions,
      stdoutHandle = AsyncProcess.Pipe,
    )
  except CancelledError as error:
    raise error
  except CatchableError as parent:
    raise newException(
      HardhatProcessError, "failed to start hardhat process: " & parent.msg, parent
    )

proc startNode*(
    _: type HardhatProcess,
    args: seq[string],
    debug: string | bool = false,
    name: string,
    onOutputLineCaptured: OnOutputLineCaptured = nil,
): Future[HardhatProcess] {.async: (raises: [CancelledError, NodeProcessError]).} =
  logScope:
    nodeName = name

  var logFilePath = ""

  var arguments = newSeq[string]()
  for arg in args:
    if arg.contains "--log-file=":
      logFilePath = arg.split("=")[1]
    else:
      arguments.add arg

  trace "starting hardhat node", arguments
  ## Starts a Hardhat Node with the specified arguments.
  ## Set debug to 'true' to see output of the node.
  let hardhat = HardhatProcess(
    arguments: arguments,
    debug: ($debug != "false"),
    trackedFutures: TrackedFutures.new(),
    name: name,
    onOutputLine: onOutputLineCaptured,
  )

  await hardhat.start()

  if logFilePath != "":
    hardhat.logFile = some hardhat.openLogFile(logFilePath)

  return hardhat

method onOutputLineCaptured(node: HardhatProcess, line: string) =
  logScope:
    nodeName = node.name

  if not node.onOutputLine.isNil:
    node.onOutputLine(line)

  without logFile =? node.logFile:
    return

  if error =? logFile.writeFile(line & "\n").errorOption:
    error "failed to write to hardhat file", errorCode = $error
    discard logFile.closeFile()
    node.logFile = none IoHandle

method stop*(node: HardhatProcess) {.async: (raises: []).} =
  # terminate the process
  await procCall NodeProcess(node).stop()

  if logFile =? node.logFile:
    trace "closing hardhat log file"
    discard logFile.closeFile()

method removeDataDir*(node: HardhatProcess) =
  discard
