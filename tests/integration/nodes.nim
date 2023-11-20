import pkg/questionable
import pkg/confutils
import pkg/chronicles
import pkg/libp2p
import std/osproc
import std/os
import std/sequtils
import std/streams
import std/strutils
import codex/conf
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
    process*: Process
    arguments*: seq[string]
    debug: bool
    client: ?CodexClient

proc start(node: NodeProcess) =
  if node.debug:
    node.process = osproc.startProcess(
      executable,
      workingDir,
      node.arguments,
      options={poParentStreams}
    )
  else:
    node.process = osproc.startProcess(
      executable,
      workingDir,
      node.arguments
    )

proc waitUntilOutput*(node: NodeProcess, output: string) =
  if node.debug:
    raiseAssert "cannot read node output when in debug mode"
  when defined(windows):
    # sleep(5_000)
    let lines = node.process.outputStream.lines.toSeq
    echo ">>> lines count: ", lines.len
    echo ">>> lines: ", lines
    for l in lines:
      if l.contains(output):
        return
  else:
    for line in node.process.outputStream.lines:
      if line.contains(output):
        return
  raiseAssert "node did not output '" & output & "'"

proc waitUntilStarted*(node: NodeProcess) =
  if node.debug:
    sleep(5_000)
  else:
    node.waitUntilOutput("Started codex node")

proc startNode*(args: openArray[string], debug: string | bool = false): NodeProcess =
  ## Starts a Codex Node with the specified arguments.
  ## Set debug to 'true' to see output of the node.
  let node = NodeProcess(arguments: @args, debug: ($debug != "false"))
  node.start()
  node

proc dataDir(node: NodeProcess): string =
  let config = CodexConf.load(cmdLine = node.arguments)
  config.dataDir.string

proc apiUrl*(node: NodeProcess): string =
  let config = CodexConf.load(cmdLine = node.arguments)
  "http://" & config.apiBindAddress & ":" & $config.apiPort & "/api/codex/v1"

proc discoveryAddress*(node: NodeProcess): string =
  let config = CodexConf.load(cmdLine = node.arguments)
  $config.discoveryIp & ":" & $config.discoveryPort

proc client*(node: NodeProcess): CodexClient =
  if client =? node.client:
    return client
  let client = CodexClient.new(node.apiUrl)
  node.client = some client
  client

method stop*(node: NodeProcess) {.base.} =
  if node.process != nil:
    node.process.terminate()
    discard node.process.waitForExit(timeout=5_000)
    node.process.close()
    node.process = nil
  if client =? node.client:
    node.client = none CodexClient
    client.close()

proc restart*(node: NodeProcess) =
  node.stop()
  node.start()
  node.waitUntilStarted()

proc removeDataDir*(node: NodeProcess) =
  removeDir(node.dataDir)
