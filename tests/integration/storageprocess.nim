import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos/asyncproc
import pkg/libp2p
import std/os
import std/strutils
import std/times
import storage/conf
import ./storageclient
import ./nodeprocess

export storageclient
export chronicles
export nodeprocess

{.push raises: [].}

logScope:
  topics = "integration testing storage process"

type
  StorageProcess* = ref object of NodeProcess
    client: ?StorageClient

  StorageProcessError* = object of NodeProcessError

proc raiseStorageProcessError(
    msg: string, parent: ref CatchableError
) {.raises: [StorageProcessError].} =
  raise newException(StorageProcessError, msg & ": " & parent.msg, parent)

template convertError(msg, body: typed) =
  # Don't use this in an async proc, unless body does not raise CancelledError
  try:
    body
  except CatchableError as parent:
    raiseStorageProcessError(msg, parent)

method workingDir(node: StorageProcess): string =
  return currentSourcePath() / ".." / ".." / ".."

method executable(node: StorageProcess): string =
  return "build" / "storage"

method startedOutput(node: StorageProcess): string =
  return "REST service started"

method processOptions(node: StorageProcess): set[AsyncProcessOption] =
  return {AsyncProcessOption.StdErrToStdOut}

method outputLineEndings(node: StorageProcess): string =
  return "\n"

method onOutputLineCaptured(node: StorageProcess, line: string) =
  discard

proc config(node: StorageProcess): StorageConf {.raises: [StorageProcessError].} =
  # cannot use convertError here as it uses typed parameters which forces type
  # resolution, while confutils.load uses untyped parameters and expects type
  # resolution not to happen yet. In other words, it won't compile.
  try:
    return StorageConf.load(
      cmdLine = node.arguments, quitOnFailure = false, secondarySources = nil
    )
  except ConfigurationError as parent:
    raiseStorageProcessError "Failed to load node arguments into StorageConf", parent

proc dataDir(node: StorageProcess): string {.raises: [StorageProcessError].} =
  return node.config.dataDir.string

proc apiUrl*(node: StorageProcess): string {.raises: [StorageProcessError].} =
  let config = node.config
  without apiBindAddress =? config.apiBindAddress:
    raise
      newException(StorageProcessError, "REST API not started: --api-bindaddr not set")
  return "http://" & apiBindAddress & ":" & $config.apiPort & "/api/storage/v1"

proc logFile*(node: StorageProcess): ?string {.raises: [StorageProcessError].} =
  node.config.logFile

proc client*(node: StorageProcess): StorageClient {.raises: [StorageProcessError].} =
  if client =? node.client:
    return client
  let client = StorageClient.new(node.apiUrl)
  node.client = some client
  return client

proc updateLogFile(node: StorageProcess, newLogFile: string) =
  for arg in node.arguments.mitems:
    if arg.startsWith("--log-file="):
      arg = "--log-file=" & newLogFile
      break

method restart*(node: StorageProcess) {.async.} =
  trace "restarting storage"
  await node.stop()
  if logFile =? node.logFile:
    # chronicles truncates the existing log file on start, so changed the log
    # file cli param to create a new one
    node.updateLogFile(
      logFile & "_restartedAt_" & now().format("yyyy-MM-dd'_'HH-mm-ss") & ".log"
    )
  await node.start()
  await node.waitUntilStarted()
  trace "storage process restarted"

method stop*(node: StorageProcess) {.async: (raises: []).} =
  logScope:
    nodeName = node.name

  trace "stopping storage client"
  await procCall NodeProcess(node).stop()

  if not node.process.isNil:
    trace "closing node process' streams"
    await node.process.closeWait()
    trace "node process' streams closed"

  if client =? node.client:
    await client.close()
    node.client = none StorageClient

method removeDataDir*(node: StorageProcess) {.raises: [StorageProcessError].} =
  convertError("failed to remove storage node data directory"):
    removeDir(node.dataDir)
