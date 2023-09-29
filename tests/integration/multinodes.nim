import std/os
import std/macros
import std/json
import std/httpclient
import std/sequtils
import std/strutils
import std/sequtils
import std/strutils
import pkg/chronicles
import ../ethertest
import ./codexclient
import ./nodes

export ethertest
export codexclient
export nodes

type
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
  Role* {.pure.} = enum
    Client,
    Provider,
    Validator

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

template multinodesuite*(name: string,
  startNodes: StartNodes, debugConfig: DebugConfig, body: untyped) =

  if (debugConfig.client or debugConfig.provider) and
      (enabledLogLevel > LogLevel.TRACE or
      enabledLogLevel == LogLevel.NONE):
    echo ""
    echo "More test debug logging is available by running the tests with " &
      "'-d:chronicles_log_level=TRACE " &
      "-d:chronicles_disabled_topics=websock " &
      "-d:chronicles_default_output_device=stdout " &
      "-d:chronicles_sinks=textlines'"
    echo ""

  ethersuite name:

    var running: seq[RunningNode]
    var bootstrap: string

    proc newNodeProcess(index: int,
                        addlOptions: seq[string],
                        debug: bool): (NodeProcess, string, Address) =

      if index > accounts.len - 1:
        raiseAssert("Cannot start node at index " & $index &
          ", not enough eth accounts.")

      let datadir = getTempDir() / "Codex" & $index
      let logdir = currentSourcePath.parentDir()
      var options = @[
        "--api-port=" & $(8080 + index),
        "--data-dir=" & datadir,
        "--nat=127.0.0.1",
        "--disc-ip=127.0.0.1",
        "--disc-port=" & $(8090 + index),
        "--eth-account=" & $accounts[index],
        "--log-file=" & (logdir / "codex" & $index & ".log")]
        .concat(addlOptions)
      if debug: options.add "--log-level=INFO;TRACE: " & debugConfig.topics
      let node = startNode(options, debug = debug)
      node.waitUntilStarted()
      (node, datadir, accounts[index])

    proc newCodexClient(index: int): CodexClient =
      CodexClient.new("http://localhost:" & $(8080 + index) & "/api/codex/v1")

    proc startClientNode() =
      let index = running.len
      let (node, datadir, account) = newNodeProcess(
        index, @["--persistence"], debugConfig.client)
      let restClient = newCodexClient(index)
      running.add RunningNode.new(Role.Client, node, restClient, datadir,
                                  account)
      if debugConfig.client:
        debug "started new client node and codex client",
          restApiPort = 8080 + index, discPort = 8090 + index, account

    proc startProviderNode(cliOptions: seq[CliOption]) =
      let index = running.len
      var options = @[
        "--bootstrap-node=" & bootstrap,
        "--persistence"
      ]

      for cliOption in cliOptions:
        var option = cliOption.key
        if cliOption.value.len > 0:
          option &= "=" & cliOption.value
        options.add option

      let (node, datadir, account) = newNodeProcess(index, options,
                                                    debugConfig.provider)
      let restClient = newCodexClient(index)
      running.add RunningNode.new(Role.Provider, node, restClient, datadir,
                                  account)
      if debugConfig.provider:
        debug "started new provider node and codex client",
          restApiPort = 8080 + index, discPort = 8090 + index, account,
          cliOptions = options.join(",")

    proc startValidatorNode() =
      let index = running.len
      let (node, datadir, account) = newNodeProcess(index, @[
        "--bootstrap-node=" & bootstrap,
        "--validator"],
        debugConfig.validator)
      let restClient = newCodexClient(index)
      running.add RunningNode.new(Role.Validator, node, restClient, datadir,
                                  account)
      if debugConfig.validator:
        debug "started new validator node and codex client",
          restApiPort = 8080 + index, discPort = 8090 + index, account

    proc clients(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Client)

    proc providers(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Provider)

    proc validators(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Validator)

    setup:
      for i in 0..<startNodes.clients:
        startClientNode()
        if i == 0:
          bootstrap = running[0].restClient.info()["spr"].getStr()

      for i in 0..<startNodes.providers:
        let cliOptions = startNodes.providerCliOptions.filter(
          proc(o: CliOption): bool = o.nodeIdx == i
        )
        startProviderNode(cliOptions)

      for i in 0..<startNodes.validators:
        startValidatorNode()

    teardown:
      for r in running:
        r.restClient.close()
        r.node.stop()
        removeDir(r.datadir)
      running = @[]

    body
