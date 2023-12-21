import std/os
import std/sequtils
import std/strutils
import std/sugar
import std/times
import pkg/codex/logutils
import pkg/chronos/transports/stream
import pkg/ethers
import pkg/asynctest
import ./hardhatprocess
import ./codexprocess
import ./hardhatconfig
import ./codexconfig
import ../checktest

export asynctest
export ethers except `%`
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

proc nextFreePort(startPort: int): Future[int] {.async.} =

  proc client(server: StreamServer, transp: StreamTransport) {.async.} =
    await transp.closeWait()

  var port = startPort
  while true:
    trace "checking if port is free", port
    try:
      let host = initTAddress("127.0.0.1", port)
      # We use ReuseAddr here only to be able to reuse the same IP/Port when
      # there's a TIME_WAIT socket. It's useful when running the test multiple
      # times or if a test ran previously using the same port.
      var server = createStreamServer(host, client, {ReuseAddr})
      trace "port is free", port
      await server.closeWait()
      return port
    except TransportOsError:
      trace "port is not free", port
      inc port

template multinodesuite*(name: string, body: untyped) =

  asyncchecksuite name:

    var running: seq[RunningNode]
    var bootstrap: string
    let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")
    var currentTestName = ""
    var nodeConfigs: NodeConfigs
    var ethProvider {.inject, used.}: JsonRpcProvider
    var accounts {.inject, used.}: seq[Address]
    var snapshot: JsonNode

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

      var args: seq[string] = @[]
      if config.logFile:
        let updatedLogFile = getLogFile(role, none int)
        args.add "--log-file=" & updatedLogFile

      let node = await HardhatProcess.startNode(args, config.debugEnabled, "hardhat")
      await node.waitUntilStarted()

      trace "hardhat node started"
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
      await node.waitUntilStarted()
      trace "node started", nodeName = $role & $roleIdx

      return node

    proc hardhat: HardhatProcess =
      for r in running:
        if r.role == Role.Hardhat:
          return HardhatProcess(r.node)
      return nil

    proc clients: seq[CodexProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Client:
            CodexProcess(r.node)

    proc providers: seq[CodexProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Provider:
            CodexProcess(r.node)

    proc validators: seq[CodexProcess] {.used.} =
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
      if not nodeConfigs.hardhat.isNil:
        let node = await startHardhatNode()
        running.add RunningNode(role: Role.Hardhat, node: node)

      try:
        ethProvider = JsonRpcProvider.new("ws://localhost:8545")
        # if hardhat was NOT started by the test, take a snapshot so it can be
        # reverted in the test teardown
        if nodeConfigs.hardhat.isNil:
          snapshot = await send(ethProvider, "evm_snapshot")
        accounts = await ethProvider.listAccounts()
      except CatchableError as e:
        fatal "failed to connect to hardhat", error = e.msg
        raiseAssert "Hardhat not running. Run hardhat manually before executing tests, or include a HardhatConfig in the test setup."

      if not nodeConfigs.clients.isNil:
        for i in 0..<nodeConfigs.clients.numNodes:
          let node = await startClientNode()
          running.add RunningNode(
                        role: Role.Client,
                        node: node
                      )
          if i == 0:
            bootstrap = CodexProcess(node).client.info()["spr"].getStr()

      if not nodeConfigs.providers.isNil:
        for i in 0..<nodeConfigs.providers.numNodes:
          let node = await startProviderNode()
          running.add RunningNode(
                        role: Role.Provider,
                        node: node
                      )

      if not nodeConfigs.validators.isNil:
        for i in 0..<nodeConfigs.validators.numNodes:
          let node = await startValidatorNode()
          running.add RunningNode(
                        role: Role.Validator,
                        node: node
                      )

    teardown:
      for nodes in @[validators(), clients(), providers()]:
        for node in nodes:
          await node.stop() # also stops rest client
          node.removeDataDir()

      # if hardhat was started in the test, kill the node
      # otherwise revert the snapshot taken in the test setup
      let hardhat = hardhat()
      if not hardhat.isNil:
        await hardhat.stop()
      else:
        discard await send(ethProvider, "evm_revert", @[snapshot])

      running = @[]

    body
