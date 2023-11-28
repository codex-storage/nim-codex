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

export codexclient
export chronicles

logScope:
  topics = "integration testing nodes"

const workingDir = currentSourcePath() / ".." / ".." / ".."
const executable = "build" / "codex"

type
  NodeProcess* = ref object of RootObj
    process*: AsyncProcessRef
    arguments*: seq[string]
    debug: bool
    client: ?CodexClient
    trackedFutures*: TrackedFutures

proc start(node: NodeProcess) {.async.} =
  node.process = await startProcess(
    executable,
    workingDir,
    node.arguments,
    options = {AsyncProcessOption.StdErrToStdOut},
    stdoutHandle = AsyncProcess.Pipe
  )

proc waitUntilOutput*(node: NodeProcess, output: string, started: Future[void]) {.async.} =
  let stream = node.process.stdOutStream

  try:
    while(let line = await stream.readLine(0, "\n"); line != ""):
      if node.debug:
        echo line

      if line.contains(output):
        started.complete()

      await sleepAsync(1.millis)
  except AsyncStreamReadError as e:
    echo "error reading node output stream: ", e.msgDetail

proc startNode*(args: seq[string], debug: string | bool = false): Future[NodeProcess] {.async.} =
  ## Starts a Codex Node with the specified arguments.
  ## Set debug to 'true' to see output of the node.
  let node = NodeProcess(
    arguments: @args,
    debug: ($debug != "false"),
    trackedFutures: TrackedFutures.new()
  )
  await node.start()
  node

proc dataDir(node: NodeProcess): string =
  let config = CodexConf.load(cmdLine = node.arguments)
  config.dataDir.string

proc apiUrl*(node: NodeProcess): string =
  let config = CodexConf.load(cmdLine = node.arguments)
  "http://" & config.apiBindAddress & ":" & $config.apiPort & "/api/codex/v1"

proc apiPort(node: NodeProcess): string =
  let config = CodexConf.load(cmdLine = node.arguments)
  $config.apiPort

proc discoveryAddress*(node: NodeProcess): string =
  let config = CodexConf.load(cmdLine = node.arguments)
  $config.discoveryIp & ":" & $config.discoveryPort

proc client*(node: NodeProcess): CodexClient =
  if client =? node.client:
    return client
  let client = CodexClient.new(node.apiUrl)
  node.client = some client
  client

proc closeAndWaitClient(node: NodeProcess) {.async.} =
  without client =? node.client:
    return

  try:
    client.close()
    echo "waiting for port ", node.apiPort, " to be closed..."
    let cmd = when defined(windows):
                "netstat -ano | findstr "
              else:
                "lsof -ti:"
    while true:
      let portInUse = await execCommandEx(cmd & node.apiPort)
      if portInUse.stdOutput == "":
        echo "port ", node.apiPort, " is no longer in use, continuing..."
        break
    node.client = none CodexClient
  except CatchableError as e:
    echo "Failed to close codex client: ", e.msg

method stop*(node: NodeProcess) {.base, async.} =
  await node.trackedFutures.cancelTracked()
  if node.process != nil:
    if err =? node.process.terminate().errorOption:
      echo "ERROR terminating node process, error code: ", err
    echo "stopping codex client"
    discard await node.process.waitForExit(timeout=5.seconds)
    await node.process.closeWait()
    if client =? node.client:
      client.close()
      node.client = none CodexClient
    # await node.closeAndWaitClient().wait(5.seconds)
    node.process = nil
    echo "code node and client stopped"

proc waitUntilStarted*(node: NodeProcess) {.async.} =
  let started = newFuture[void]()
  let output = "REST service started"
  try:
    discard node.waitUntilOutput(output, started).track(node)
    await started.wait(5.seconds)
  except AsyncTimeoutError as e:
    await node.stop() # allows subsequent tests to continue
    raiseAssert "node did not output '" & output & "'"

proc restart*(node: NodeProcess) {.async.} =
  await node.stop()
  await node.start()
  await node.waitUntilStarted()

proc removeDataDir*(node: NodeProcess) =
  removeDir(node.dataDir)
