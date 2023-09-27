# import std/dirs
import std/httpclient
import std/json
import std/macros
import std/os
import std/sequtils
import std/strformat
import std/strutils
import std/sugar
import std/times
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
    clients*: StartNodeConfig
    providers*: StartNodeConfig
    validators*: StartNodeConfig
  StartNodeConfig* = object
    numNodes*: int
    cliOptions*: seq[CliOption]
    logFile*: bool
    logTopics*: seq[string]
    debugEnabled*: bool
  Role* {.pure.} = enum
    Client,
    Provider,
    Validator
  CliOption* = object of RootObj
    nodeIdx*: ?int
    key*: string
    value*: string

proc `$`*(option: CliOption): string =
  var res = option.key
  if option.value.len > 0:
    res &= "=" & option.value
  return res

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

proc nodes*(config: StartNodeConfig, numNodes: int): StartNodeConfig =
  if numNodes < 0:
    raise newException(ValueError, "numNodes must be >= 0")

  var startConfig = config
  startConfig.numNodes = numNodes
  return startConfig

proc simulateProofFailuresFor*(
  config: StartNodeConfig,
  providerIdx: int,
  failEveryNProofs: int
): StartNodeConfig =

  if providerIdx > config.numNodes - 1:
    raise newException(ValueError, "provider index out of bounds")

  var startConfig = config
  startConfig.cliOptions.add(
    CliOption(
      nodeIdx: some providerIdx,
      key: "--simulate-proof-failures",
      value: $failEveryNProofs
    )
  )
  return startConfig

proc debug*(config: StartNodeConfig, enabled = true): StartNodeConfig =
  ## output log in stdout
  var startConfig = config
  startConfig.debugEnabled = enabled
  return startConfig

# proc withLogFile*(
#   config: StartNodeConfig,
#   file: bool | string
# ): StartNodeConfig =

#   var startConfig = config
#   when file is bool:
#     if not file: startConfig.logFile = none string
#     else: startConfig.logFile =
#             some currentSourcePath.parentDir() / "codex" & $index & ".log"
#   else:
#     if file.len <= 0:
#       raise newException(ValueError, "file path length must be > 0")
#     startConfig.logFile = some file

#   return startConfig

proc withLogTopics*(
  config: StartNodeConfig,
  topics: varargs[string]
): StartNodeConfig =

  var startConfig = config
  startConfig.logTopics = startConfig.logTopics.concat(@topics)
  return startConfig

proc withLogFile*(
  config: StartNodeConfig,
  logToFile: bool = true
): StartNodeConfig =

  var startConfig = config
  var logDir = currentSourcePath.parentDir() / "logs" / "{starttime}"
  createDir(logDir)
  startConfig.logFile = logToFile
  return startConfig

template multinodesuite*(name: string,
  startNodes: StartNodes, body: untyped) =

  ethersuite name:

    var running: seq[RunningNode]
    var bootstrap: string
    let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")

    proc newNodeProcess(index: int,
                        config: StartNodeConfig
    ): (NodeProcess, string, Address) =

      if index > accounts.len - 1:
        raiseAssert("Cannot start node at index " & $index &
          ", not enough eth accounts.")

      let datadir = getTempDir() / "Codex" & $index
      # let logdir = currentSourcePath.parentDir()
      var options = config.cliOptions.map(o => $o)
        .concat(@[
          "--api-port=" & $(8080 + index),
          "--data-dir=" & datadir,
          "--nat=127.0.0.1",
          "--listen-addrs=/ip4/127.0.0.1/tcp/0",
          "--disc-ip=127.0.0.1",
          "--disc-port=" & $(8090 + index),
          "--eth-account=" & $accounts[index]])
      # if logFile =? config.logFile:
      #   options.add "--log-file=" & logFile
      if config.logTopics.len > 0:
        options.add "--log-level=INFO;TRACE: " & config.logTopics.join(",")

      let node = startNode(options, config.debugEnabled)
      node.waitUntilStarted()
      (node, datadir, accounts[index])

    proc clients(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Client)

    proc providers(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Provider)

    proc validators(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Validator)

    proc newCodexClient(index: int): CodexClient =
      CodexClient.new("http://localhost:" & $(8080 + index) & "/api/codex/v1")

    proc getLogFile(role: Role, index: int): string =
      var logDir = currentSourcePath.parentDir() / "logs" / $starttime
      createDir(logDir)
      let fn = $role & "_" & $index & ".log"
      let fileName = logDir / fn
      echo ">>> replace log file name: ", fileName
      return fileName

    proc startClientNode() =
      let index = running.len
      let clientIdx = clients().len
      var config = startNodes.clients
      config.cliOptions.add CliOption(key: "--persistence")
      if config.logFile:
        let updatedLogFile = getLogFile(Role.Client, clientIdx)
        config.cliOptions.add CliOption(key: "--log-file", value: updatedLogFile)
      let (node, datadir, account) = newNodeProcess(index, config)
      let restClient = newCodexClient(index)
      running.add RunningNode.new(Role.Client, node, restClient, datadir,
                                  account)
      if config.debugEnabled:
        debug "started new client node and codex client",
          restApiPort = 8080 + index, discPort = 8090 + index, account

    proc startProviderNode(cliOptions: seq[CliOption] = @[]) =
      let index = running.len
      let providerIdx = providers().len
      var config = startNodes.providers
      config.cliOptions = config.cliOptions.concat(cliOptions)
      if config.logFile:
        let updatedLogFile = getLogFile(Role.Provider, providerIdx)
        config.cliOptions.add CliOption(key: "--log-file", value: updatedLogFile)
      config.cliOptions.add CliOption(key: "--bootstrap-node", value: bootstrap)
      config.cliOptions.add CliOption(key: "--persistence")

      config.cliOptions = config.cliOptions.filter(
        o => (let idx = o.nodeIdx |? providerIdx; echo "idx: ", idx, ", index: ", index; idx == providerIdx)
      )

      let (node, datadir, account) = newNodeProcess(index, config)
      let restClient = newCodexClient(index)
      running.add RunningNode.new(Role.Provider, node, restClient, datadir,
                                  account)
      if config.debugEnabled:
        debug "started new provider node and codex client",
          restApiPort = 8080 + index, discPort = 8090 + index, account,
          cliOptions = config.cliOptions.join(",")

    proc startValidatorNode() =
      let index = running.len
      let validatorIdx = providers().len
      var config = startNodes.validators
      if config.logFile:
        let updatedLogFile = getLogFile(Role.Validator, validatorIdx)
        config.cliOptions.add CliOption(key: "--log-file", value: updatedLogFile)
      config.cliOptions.add CliOption(key: "--bootstrap-node", value: bootstrap)
      config.cliOptions.add CliOption(key: "--validator")

      let (node, datadir, account) = newNodeProcess(index, config)
      let restClient = newCodexClient(index)
      running.add RunningNode.new(Role.Validator, node, restClient, datadir,
                                  account)
      if config.debugEnabled:
        debug "started new validator node and codex client",
          restApiPort = 8080 + index, discPort = 8090 + index, account

    setup:
      for i in 0..<startNodes.clients.numNodes:
        startClientNode()
        if i == 0:
          bootstrap = running[0].restClient.info()["spr"].getStr()

      for i in 0..<startNodes.providers.numNodes:
        startProviderNode()

      for i in 0..<startNodes.validators.numNodes:
        startValidatorNode()

    teardown:
      for r in running:
        r.restClient.close()
        r.node.stop()
        removeDir(r.datadir)
      running = @[]

    body
