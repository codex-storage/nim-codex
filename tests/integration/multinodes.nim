import std/os
import std/sequtils
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
  NodeConfigs* = object
    clients*: NodeConfig
    providers*: NodeConfig
    validators*: NodeConfig
    hardhat*: HardhatConfig
  Config* = object of RootObj
    logFile*: bool
  NodeConfig* = object of Config
    numNodes*: int
    cliOptions*: seq[CliOption]
    logTopics*: seq[string]
    debugEnabled*: bool
  HardhatConfig* = ref object of Config
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

proc nodes*(config: NodeConfig, numNodes: int): NodeConfig =
  if numNodes < 0:
    raise newException(ValueError, "numNodes must be >= 0")

  var startConfig = config
  startConfig.numNodes = numNodes
  return startConfig

proc simulateProofFailuresFor*(
  config: NodeConfig,
  providerIdx: int,
  failEveryNProofs: int
): NodeConfig =

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

proc debug*(config: NodeConfig, enabled = true): NodeConfig =
  ## output log in stdout
  var startConfig = config
  startConfig.debugEnabled = enabled
  return startConfig

proc withLogTopics*(
  config: NodeConfig,
  topics: varargs[string]
): NodeConfig =

  var startConfig = config
  startConfig.logTopics = startConfig.logTopics.concat(@topics)
  return startConfig

proc withLogFile*[T: Config](
  config: T,
  logToFile: bool = true
): T =

  var startConfig = config
  startConfig.logFile = logToFile
  return startConfig

proc nextFreePort(startPort: int): Future[int] {.async.} =
  let cmd = when defined(windows):
              "netstat -ano | findstr :"
            else:
              "lsof -ti:"
  var port = startPort
  while true:
    let portInUse = await execCommandEx(cmd & $port)
    if portInUse.stdOutput == "":
      echo "port ", port, " is free"
      return port
    else:
      inc port

template multinodesuite*(name: string, body: untyped) =

  ethersuite name:

    var running: seq[RunningNode]
    var bootstrap: string
    let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")
    var currentTestName = ""
    var nodeConfigs: NodeConfigs

    template test(tname, startNodeConfigs, tbody) =
      currentTestName = tname
      nodeConfigs = startNodeConfigs
      test tname:
        tbody

    proc sanitize(pathSegment: string): string =
      var sanitized = pathSegment
      for invalid in invalidFilenameChars.items:
        sanitized = sanitized.replace(invalid, '_')
      sanitized

    proc getLogFile(role: Role, index: ?int): string =
      # create log file path, format:
      # tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log

      var logDir = currentSourcePath.parentDir() /
        "logs" /
        sanitize($starttime & " " & name) /
        sanitize($currentTestName)
      createDir(logDir)

      var fn = $role
      if idx =? index:
        fn &= "_" & $idx
      fn &= ".log"

      let fileName = logDir / fn
      return fileName

    proc newHardhatProcess(
      config: HardhatConfig,
      role: Role
    ): Future[NodeProcess] {.async.} =

      var options: seq[string] = @[]
      if config.logFile:
        let updatedLogFile = getLogFile(role, none int)
        options.add "--log-file=" & updatedLogFile

      let node = await startHardhatProcess(options)
      await node.waitUntilStarted()

      debug "started new hardhat node"
      return node

    proc newNodeProcess(roleIdx: int,
                        config1: NodeConfig,
                        role: Role
    ): Future[NodeProcess] {.async.} =

      let nodeIdx = running.len
      var config = config1

      if nodeIdx > accounts.len - 1:
        raiseAssert("Cannot start node at nodeIdx " & $nodeIdx &
          ", not enough eth accounts.")

      let datadir = getTempDir() / "Codex" /
        sanitize($starttime) /
        sanitize($role & "_" & $roleIdx)

      if config.logFile:
        let updatedLogFile = getLogFile(role, some roleIdx)
        config.cliOptions.add CliOption(key: "--log-file", value: updatedLogFile)

      if config.logTopics.len > 0:
        config.cliOptions.add CliOption(key: "--log-level", value: "INFO;TRACE: " & config.logTopics.join(","))

      var options = config.cliOptions.map(o => $o)
        .concat(@[
          "--api-port=" & $ await nextFreePort(8080 + nodeIdx),
          "--data-dir=" & datadir,
          "--nat=127.0.0.1",
          "--listen-addrs=/ip4/127.0.0.1/tcp/0",
          "--disc-ip=127.0.0.1",
          "--disc-port=" & $ await nextFreePort(8090 + nodeIdx),
          "--eth-account=" & $accounts[nodeIdx]])

      let node = await startNode(options, config.debugEnabled)
      echo "[multinodes.newNodeProcess] waiting until ", role, " node started"
      await node.waitUntilStarted()
      echo "[multinodes.newNodeProcess] ", role, " NODE STARTED"

      return node

    proc clients(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Client)

    proc providers(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Provider)

    proc validators(): seq[RunningNode] {.used.} =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Validator)

    proc startHardhatNode(): Future[NodeProcess] {.async.} =
      var config = nodeConfigs.hardhat
      return await newHardhatProcess(config, Role.Hardhat)

    proc startClientNode(): Future[NodeProcess] {.async.} =
      let clientIdx = clients().len
      var config = nodeConfigs.clients
      config.cliOptions.add CliOption(key: "--persistence")
      return await newNodeProcess(clientIdx, config, Role.Client)

    proc startProviderNode(): Future[NodeProcess] {.async.} =
      let providerIdx = providers().len
      var config = nodeConfigs.providers
      config.cliOptions.add CliOption(key: "--bootstrap-node", value: bootstrap)
      config.cliOptions.add CliOption(key: "--persistence")

      # filter out provider options by provided index
      config.cliOptions = config.cliOptions.filter(
        o => (let idx = o.nodeIdx |? providerIdx; idx == providerIdx)
      )

      return await newNodeProcess(providerIdx, config, Role.Provider)

    proc startValidatorNode(): Future[NodeProcess] {.async.} =
      let validatorIdx = validators().len
      var config = nodeConfigs.validators
      config.cliOptions.add CliOption(key: "--bootstrap-node", value: bootstrap)
      config.cliOptions.add CliOption(key: "--validator")

      return await newNodeProcess(validatorIdx, config, Role.Validator)

    setup:
      if not nodeConfigs.hardhat.isNil:
        let node = await startHardhatNode()
        running.add RunningNode(role: Role.Hardhat, node: node)

      for i in 0..<nodeConfigs.clients.numNodes:
        echo "[multinodes.setup] starting client node ", i
        let node = await startClientNode()
        running.add RunningNode(
                      role: Role.Client,
                      node: node,
                      address: some accounts[running.len]
                    )
        echo "[multinodes.setup] added running client node ", i
        if i == 0:
          echo "[multinodes.setup] getting client 0 bootstrap spr"
          bootstrap = node.client.info()["spr"].getStr()
          echo "[multinodes.setup] got client 0 bootstrap spr: ", bootstrap

      for i in 0..<nodeConfigs.providers.numNodes:
        echo "[multinodes.setup] starting provider node ", i
        let node = await startProviderNode()
        running.add RunningNode(
                      role: Role.Provider,
                      node: node,
                      address: some accounts[running.len]
                    )
        echo "[multinodes.setup] added running provider node ", i

      for i in 0..<nodeConfigs.validators.numNodes:
        let node = await startValidatorNode()
        running.add RunningNode(
                      role: Role.Validator,
                      node: node,
                      address: some accounts[running.len]
                    )
        echo "[multinodes.setup] added running validator node ", i

    teardown:
      for r in running:
        await r.node.stop() # also stops rest client
        r.node.removeDataDir()
      running = @[]

    body
