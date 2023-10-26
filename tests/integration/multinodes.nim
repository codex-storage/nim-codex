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
import ./hardhat
import ./nodes

export ethertest
export codexclient
export nodes

type
  RunningNode* = ref object
    role*: Role
    node*: NodeProcess
    address*: ?Address
  StartNodes* = object
    clients*: StartNodeConfig
    providers*: StartNodeConfig
    validators*: StartNodeConfig
    hardhat*: StartHardhatConfig
  StartNodeConfig* = object
    numNodes*: int
    cliOptions*: seq[CliOption]
    logFile*: bool
    logTopics*: seq[string]
    debugEnabled*: bool
  StartHardhatConfig* = ref object
    logFile*: bool
  Role* {.pure.} = enum
    Client,
    Provider,
    Validator,
    Hardhat
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
          node: NodeProcess): RunningNode =
  RunningNode(role: role,
              node: node)

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
  startConfig.logFile = logToFile
  return startConfig

proc withLogFile*(
  config: StartHardhatConfig,
  logToFile: bool = true
): StartHardhatConfig =

  var startConfig = config
  startConfig.logFile = logToFile
  return startConfig

template multinodesuite*(name: string,
  startNodes: StartNodes, body: untyped) =

  asyncchecksuite name:

    var provider {.inject, used.}: JsonRpcProvider
    var accounts {.inject, used.}: seq[Address]

    var running: seq[RunningNode]
    var bootstrap: string
    let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")

    proc getLogFile(role: Role, index: ?int): string =
      var nameSanitized = name
      for invalid in invalidFilenameChars.items:
        nameSanitized = nameSanitized.replace(invalid, '_')
      var logDir = currentSourcePath.parentDir() / "logs" / nameSanitized / $starttime
      createDir(logDir)
      var fn = $role
      if idx =? index:
        fn &= "_" & $idx
      fn &= ".log"
      let fileName = logDir / fn
      return fileName

    proc newHardhatProcess(config: StartHardhatConfig, role: Role): NodeProcess =
      var options: seq[string] = @[]
      if config.logFile:
        let updatedLogFile = getLogFile(role, none int)
        options.add "--log-file=" & updatedLogFile

      let node = startHardhatProcess(options)
      node.waitUntilStarted()

      debug "started new hardhat node"
      return node

    proc newNodeProcess(roleIdx: int,
                        config1: StartNodeConfig,
                        role: Role
    ): NodeProcess =

      let nodeIdx = running.len
      var config = config1

      if nodeIdx > accounts.len - 1:
        raiseAssert("Cannot start node at nodeIdx " & $nodeIdx &
          ", not enough eth accounts.")

      let datadir = getTempDir() / "Codex" / $starttime / $role & "_" & $roleIdx

      if config.logFile:
        let updatedLogFile = getLogFile(role, some roleIdx)
        config.cliOptions.add CliOption(key: "--log-file", value: updatedLogFile)

      if config.logTopics.len > 0:
        config.cliOptions.add CliOption(key: "--log-level", value: "INFO;TRACE: " & config.logTopics.join(","))

      var options = config.cliOptions.map(o => $o)
        .concat(@[
          "--api-port=" & $(8080 + nodeIdx),
          "--data-dir=" & datadir,
          "--nat=127.0.0.1",
          "--listen-addrs=/ip4/127.0.0.1/tcp/0",
          "--disc-ip=127.0.0.1",
          "--disc-port=" & $(8090 + nodeIdx),
          "--eth-account=" & $accounts[nodeIdx]])

      let node = startNode(options, config.debugEnabled)
      node.waitUntilStarted()

      if config.debugEnabled:
        debug "started new integration testing node and codex client",
          role,
          apiUrl = node.apiUrl,
          discAddress = node.discoveryAddress,
          address = accounts[nodeIdx],
          cliOptions = config.cliOptions.join(",")

      return node

    proc clients(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Client)

    proc providers(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Provider)

    proc validators(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Validator)

    proc startHardhatNode(): NodeProcess =
      var config = startNodes.hardhat
      return newHardhatProcess(config, Role.Hardhat)

    proc startClientNode(): NodeProcess =
      let clientIdx = clients().len
      var config = startNodes.clients
      config.cliOptions.add CliOption(key: "--persistence")
      return newNodeProcess(clientIdx, config, Role.Client)

    proc startProviderNode(): NodeProcess =
      let providerIdx = providers().len
      var config = startNodes.providers
      config.cliOptions.add CliOption(key: "--bootstrap-node", value: bootstrap)
      config.cliOptions.add CliOption(key: "--persistence")

      # filter out provider options by provided index
      config.cliOptions = config.cliOptions.filter(
        o => (let idx = o.nodeIdx |? providerIdx; idx == providerIdx)
      )

      return newNodeProcess(providerIdx, config, Role.Provider)

    proc startValidatorNode(): NodeProcess =
      let validatorIdx = validators().len
      var config = startNodes.validators
      config.cliOptions.add CliOption(key: "--bootstrap-node", value: bootstrap)
      config.cliOptions.add CliOption(key: "--validator")

      return newNodeProcess(validatorIdx, config, Role.Validator)

    setup:
      if not startNodes.hardhat.isNil:
        let node = startHardhatNode()
        running.add RunningNode(role: Role.Hardhat, node: node)

      echo "Connecting to hardhat on ws://localhost:8545..."
      provider = JsonRpcProvider.new("ws://localhost:8545")
      accounts = await provider.listAccounts()

      for i in 0..<startNodes.clients.numNodes:
        let node = startClientNode()
        running.add RunningNode(
                      role: Role.Client,
                      node: node,
                      address: some accounts[running.len]
                    )
        if i == 0:
          bootstrap = node.client.info()["spr"].getStr()

      for i in 0..<startNodes.providers.numNodes:
        let node = startProviderNode()
        running.add RunningNode(
                      role: Role.Provider,
                      node: node,
                      address: some accounts[running.len]
                    )

      for i in 0..<startNodes.validators.numNodes:
        let node = startValidatorNode()
        running.add RunningNode(
                      role: Role.Validator,
                      node: node,
                      address: some accounts[running.len]
                    )

    teardown:
      for r in running:
        r.node.stop() # also stops rest client
        r.node.removeDataDir()
      running = @[]

    body
