import std/osproc
import std/os
import std/streams
import std/strutils
import pkg/ethers
import ./codexclient

const workingDir = currentSourcePath() / ".." / ".." / ".."
const executable = "build" / "codex"

type
  NodeProcess* = ref object
    process: Process
    arguments: seq[string]
    debug: bool
  Role* = enum
    Client,
    Provider,
    Validator
  RunningNode* = ref object
    role*: Role
    node*: NodeProcess
    restClient*: CodexClient
    datadir*: string
    ethAccount*: Address
  StartNodes* = object
    clients*: uint
    providers*: uint
    validators*: uint
  DebugNodes* = object
    client*: bool
    provider*: bool
    validator*: bool
    topics*: string

proc new*(_: type RunningNode,
          role: Role,
          node: NodeProcess,
          restClient: CodexClient,
          datadir: string,
          ethAccount: Address): RunningNode =
  RunningNode(role: role,
              node: node,
              restClient: restClient,
              datadir: datadir,
              ethAccount: ethAccount)

proc init*(_: type StartNodes,
          clients, providers, validators: uint): StartNodes =
  StartNodes(clients: clients, providers: providers, validators: validators)

proc init*(_: type DebugNodes,
          client, provider, validator: bool,
          topics: string = "validator,proving,market"): DebugNodes =
  DebugNodes(client: client, provider: provider, validator: validator,
             topics: topics)

proc start(node: NodeProcess) =
  if node.debug:
    node.process = startProcess(
      executable,
      workingDir,
      node.arguments,
      options={poParentStreams}
    )
    sleep(1000)
  else:
    node.process = startProcess(
      executable,
      workingDir,
      node.arguments
    )
    for line in node.process.outputStream.lines:
      if line.contains("Started codex node"):
        break

proc startNode*(args: openArray[string], debug = false): NodeProcess =
  ## Starts a Codex Node with the specified arguments.
  ## Set debug to 'true' to see output of the node.
  let node = NodeProcess(arguments: @args, debug: debug)
  node.start()
  node

proc stop*(node: NodeProcess) =
  if node.process != nil:
    node.process.terminate()
    discard node.process.waitForExit(timeout=5_000)
    node.process.close()
    node.process = nil

proc restart*(node: NodeProcess) =
  node.stop()
  node.start()
