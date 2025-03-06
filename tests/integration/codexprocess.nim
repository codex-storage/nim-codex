import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos/asyncproc
import pkg/ethers
import pkg/libp2p
import std/os
import std/strutils
import std/times
import codex/conf
import ./codexclient
import ./nodeprocess

export codexclient
export chronicles
export nodeprocess

{.push raises: [].}

logScope:
  topics = "integration testing codex process"

type
  CodexProcess* = ref object of NodeProcess
    client: ?CodexClient

  CodexProcessError* = object of NodeProcessError

proc raiseCodexProcessError(
    msg: string, parent: ref CatchableError
) {.raises: [CodexProcessError].} =
  raise newException(CodexProcessError, msg & ": " & parent.msg, parent)

template convertError(msg, body: typed) =
  try:
    body
  except CatchableError as parent:
    raiseCodexProcessError(msg, parent)

method workingDir(node: CodexProcess): string =
  return currentSourcePath() / ".." / ".." / ".."

method executable(node: CodexProcess): string =
  return "build" / "codex"

method startedOutput(node: CodexProcess): string =
  return "REST service started"

method processOptions(node: CodexProcess): set[AsyncProcessOption] =
  return {AsyncProcessOption.StdErrToStdOut}

method outputLineEndings(node: CodexProcess): string =
  return "\n"

method onOutputLineCaptured(node: CodexProcess, line: string) =
  discard

proc config(node: CodexProcess): CodexConf {.raises: [CodexProcessError].} =
  # cannot use convertError here as it uses typed parameters which forces type
  # resolution, while confutils.load uses untyped parameters and expects type
  # resolution not to happen yet. In other words, it won't compile.
  try:
    return CodexConf.load(
      cmdLine = node.arguments, quitOnFailure = false, secondarySources = nil
    )
  except ConfigurationError as parent:
    raiseCodexProcessError "Failed to load node arguments into CodexConf", parent

proc dataDir(node: CodexProcess): string {.raises: [CodexProcessError].} =
  return node.config.dataDir.string

proc ethAccount*(node: CodexProcess): Address {.raises: [CodexProcessError].} =
  without ethAccount =? node.config.ethAccount:
    raiseAssert "eth account not set"
  return Address(ethAccount)

proc apiUrl*(node: CodexProcess): string {.raises: [CodexProcessError].} =
  let config = node.config
  return "http://" & config.apiBindAddress & ":" & $config.apiPort & "/api/codex/v1"

proc logFile*(node: CodexProcess): ?string {.raises: [CodexProcessError].} =
  node.config.logFile

proc client*(node: CodexProcess): CodexClient {.raises: [CodexProcessError].} =
  if client =? node.client:
    return client
  let client = CodexClient.new(node.apiUrl)
  node.client = some client
  return client

proc updateLogFile(node: CodexProcess, newLogFile: string) =
  for arg in node.arguments.mitems:
    if arg.startsWith("--log-file="):
      arg = "--log-file=" & newLogFile
      break

method restart*(node: CodexProcess) {.async.} =
  trace "restarting codex"
  await node.stop()
  if logFile =? node.logFile:
    # chronicles truncates the existing log file on start, so changed the log
    # file cli param to create a new one
    node.updateLogFile(
      logFile & "_restartedAt_" & now().format("yyyy-MM-dd'_'HH-mm-ss") & ".log"
    )
  await node.start()
  await node.waitUntilStarted()
  trace "codex process restarted"

method stop*(node: CodexProcess) {.async: (raises: []).} =
  logScope:
    nodeName = node.name

  await procCall NodeProcess(node).stop()

  trace "stopping codex client"
  if client =? node.client:
    await client.close()
    node.client = none CodexClient

method removeDataDir*(node: CodexProcess) {.raises: [CodexProcessError].} =
  convertError("failed to remove codex node data directory"):
    removeDir(node.dataDir)
