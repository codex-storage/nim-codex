import std/os
import std/sequtils
import std/strutils
import std/sugar
import std/times
import pkg/chronicles
import ../ethertest
import ./hardhatprocess
import ./codexprocess
import ./hardhatconfig
import ./codexconfig

export ethertest
export hardhatprocess
export codexprocess
export hardhatconfig
export codexconfig

type
  RunningNode* = ref object
    role*: Role
    node*: NodeProcess
  NodeConfigs* = object
    clients*: CodexConfig
    providers*: CodexConfig
    validators*: CodexConfig
    hardhat*: HardhatConfig
  Role* {.pure.} = enum
    Client,
    Provider,
    Validator,
    Hardhat

proc new*(_: type RunningNode,
          role: Role,
          node: NodeProcess): RunningNode =
  RunningNode(role: role,
              node: node)

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
      echo "[multinodes] inside test template, tname: ", tname, ", startNodeConfigs: ", startNodeConfigs
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

      var args: seq[string] = @[]
      if config.logFile:
        let updatedLogFile = getLogFile(role, none int)
        args.add "--log-file=" & updatedLogFile
      echo ">>> [multinodes] starting hardhat node with args: ", args
      let node = await HardhatProcess.startNode(args, config.debugEnabled, "hardhat")
      await node.waitUntilStarted()

      debug "started new hardhat node"
      return node

    proc newCodexProcess(roleIdx: int,
                        config: CodexConfig,
                        role: Role
    ): Future[NodeProcess] {.async.} =

      let nodeIdx = running.len
      var conf = config

      if nodeIdx > accounts.len - 1:
        raiseAssert("Cannot start node at nodeIdx " & $nodeIdx &
          ", not enough eth accounts.")

      let datadir = getTempDir() / "Codex" /
        sanitize($starttime) /
        sanitize($role & "_" & $roleIdx)

      if conf.logFile:
        let updatedLogFile = getLogFile(role, some roleIdx)
        conf.cliOptions.add CliOption(key: "--log-file", value: updatedLogFile)

      let logLevel = conf.logLevel |? LogLevel.INFO
      if conf.logTopics.len > 0:
        conf.cliOptions.add CliOption(
          key: "--log-level",
          value: $logLevel & ";TRACE: " & conf.logTopics.join(",")
        )
      else:
        conf.cliOptions.add CliOption(key: "--log-level", value: $logLevel)

      var args = conf.cliOptions.map(o => $o)
        .concat(@[
          "--api-port=" & $ await nextFreePort(8080 + nodeIdx),
          "--data-dir=" & datadir,
          "--nat=127.0.0.1",
          "--listen-addrs=/ip4/127.0.0.1/tcp/0",
          "--disc-ip=127.0.0.1",
          "--disc-port=" & $ await nextFreePort(8090 + nodeIdx),
          "--eth-account=" & $accounts[nodeIdx]])

      let node = await CodexProcess.startNode(args, conf.debugEnabled, $role & $roleIdx)
      echo "[multinodes.newCodexProcess] waiting until ", role, " node started"
      await node.waitUntilStarted()
      echo "[multinodes.newCodexProcess] ", role, " NODE STARTED"

      return node

    proc clients(): seq[CodexProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Client:
            CodexProcess(r.node)

    proc providers(): seq[CodexProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Provider:
            CodexProcess(r.node)

    proc validators(): seq[CodexProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Validator:
            CodexProcess(r.node)

    proc startHardhatNode(): Future[NodeProcess] {.async.} =
      var config = nodeConfigs.hardhat
      return await newHardhatProcess(config, Role.Hardhat)

    proc startClientNode(): Future[NodeProcess] {.async.} =
      let clientIdx = clients().len
      var config = nodeConfigs.clients
      config.cliOptions.add CliOption(key: "--persistence")
      return await newCodexProcess(clientIdx, config, Role.Client)

    proc startProviderNode(): Future[NodeProcess] {.async.} =
      let providerIdx = providers().len
      var config = nodeConfigs.providers
      config.cliOptions.add CliOption(key: "--bootstrap-node", value: bootstrap)
      config.cliOptions.add CliOption(key: "--persistence")

      # filter out provider options by provided index
      config.cliOptions = config.cliOptions.filter(
        o => (let idx = o.nodeIdx |? providerIdx; idx == providerIdx)
      )

      return await newCodexProcess(providerIdx, config, Role.Provider)

    proc startValidatorNode(): Future[NodeProcess] {.async.} =
      let validatorIdx = validators().len
      var config = nodeConfigs.validators
      config.cliOptions.add CliOption(key: "--bootstrap-node", value: bootstrap)
      config.cliOptions.add CliOption(key: "--validator")

      return await newCodexProcess(validatorIdx, config, Role.Validator)

    setup:
      echo "[multinodes.setup] setup start"
      if not nodeConfigs.hardhat.isNil:
        echo "[multinodes.setup] starting hardhat node "
        let node = await startHardhatNode()
        running.add RunningNode(role: Role.Hardhat, node: node)

      if not nodeConfigs.clients.isNil:
        for i in 0..<nodeConfigs.clients.numNodes:
          echo "[multinodes.setup] starting client node ", i
          let node = await startClientNode()
          running.add RunningNode(
                        role: Role.Client,
                        node: node
                      )
          echo "[multinodes.setup] added running client node ", i
          if i == 0:
            echo "[multinodes.setup] getting client 0 bootstrap spr"
            bootstrap = CodexProcess(node).client.info()["spr"].getStr()
            echo "[multinodes.setup] got client 0 bootstrap spr: ", bootstrap

      if not nodeConfigs.providers.isNil:
        for i in 0..<nodeConfigs.providers.numNodes:
          echo "[multinodes.setup] starting provider node ", i
          let node = await startProviderNode()
          running.add RunningNode(
                        role: Role.Provider,
                        node: node
                      )
          echo "[multinodes.setup] added running provider node ", i

      if not nodeConfigs.validators.isNil:
        for i in 0..<nodeConfigs.validators.numNodes:
          let node = await startValidatorNode()
          running.add RunningNode(
                        role: Role.Validator,
                        node: node
                      )
          echo "[multinodes.setup] added running validator node ", i

    teardown:
      for r in running:
        await r.node.stop() # also stops rest client
        r.node.removeDataDir()
      running = @[]

    body
