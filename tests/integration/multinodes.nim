import std/httpclient
import std/os
import std/sequtils
import std/strutils
import std/sugar
import std/times
import pkg/codex/conf
import pkg/codex/logutils
import pkg/chronos/transports/stream
import pkg/ethers
import pkg/questionable
import ./codexconfig
import ./codexprocess
import ./hardhatconfig
import ./hardhatprocess
import ./nodeconfigs
import ./utils
import ../asynctest
import ../checktest

export asynctest
export ethers except `%`
export hardhatprocess
export codexprocess
export hardhatconfig
export codexconfig
export nodeconfigs

{.push raises: [].}

type
  RunningNode* = ref object
    role*: Role
    node*: NodeProcess

  Role* {.pure.} = enum
    Client
    Provider
    Validator
    Hardhat

  MultiNodeSuiteError = object of CatchableError
  SuiteTimeoutError = object of MultiNodeSuiteError

const HardhatPort {.intdefine.}: int = 8545
const CodexApiPort {.intdefine.}: int = 8080
const CodexDiscPort {.intdefine.}: int = 8090
const TestId {.strdefine.}: string = "TestId"
const CodexLogToFile {.booldefine.}: bool = false
const CodexLogLevel {.strdefine.}: string = ""
const CodexLogsDir {.strdefine.}: string = ""

proc raiseMultiNodeSuiteError(
    msg: string, parent: ref CatchableError = nil
) {.raises: [MultiNodeSuiteError].} =
  raise newException(MultiNodeSuiteError, msg, parent)

template withLock(lock: AsyncLock, body: untyped) =
  if lock.isNil:
    lock = newAsyncLock()

  await lock.acquire()
  try:
    body
  finally:
    try:
      lock.release()
    except AsyncLockError as parent:
      raiseMultiNodeSuiteError "lock error", parent

template multinodesuite*(suiteName: string, body: untyped) =
  asyncchecksuite suiteName:
    # Following the problem described here:
    # https://github.com/NomicFoundation/hardhat/issues/2053
    # It may be desirable to use http RPC provider.
    # This turns out to be equally important in tests where
    # subscriptions get wiped out after 5mins even when
    # a new block is mined.
    # For this reason, we are using http provider here as the default.
    # To use a different provider in your test, you may use
    # multinodesuiteWithProviderUrl template in your tests.
    # If you want to use a different provider url in the nodes, you can
    # use withEthProvider config modifier in the node config
    # to set the desired provider url. E.g.:
    #   NodeConfigs(
    #     hardhat:
    #       HardhatConfig.none,
    #     clients:
    #       CodexConfigs.init(nodes=1)
    #         .withEthProvider("ws://localhost:8545")
    #         .some,
    #     ...
    var jsonRpcProviderUrl = "http://127.0.0.1:" & $HardhatPort
    var running {.inject, used.}: seq[RunningNode]
    var bootstrapNodes: seq[string]
    let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")
    var currentTestName = ""
    var nodeConfigs: NodeConfigs
    var ethProvider {.inject, used.}: JsonRpcProvider
    var accounts {.inject, used.}: seq[Address]
    var snapshot: JsonNode
    var lastUsedHardhatPort = HardhatPort
    var lastUsedCodexApiPort = CodexApiPort
    var lastUsedCodexDiscPort = CodexDiscPort
    var codexPortLock: AsyncLock

    template test(tname, startNodeConfigs, tbody) =
      currentTestName = tname
      nodeConfigs = startNodeConfigs
      test tname:
        tbody

    proc updatePort(url: var string, port: int) =
      let parts = url.split(':')
      url = @[parts[0], parts[1], $port].join(":")

    proc newHardhatProcess(
        config: HardhatConfig, role: Role
    ): Future[NodeProcess] {.async: (raises: [MultiNodeSuiteError, CancelledError]).} =
      var args: seq[string] = @[]
      if config.logFile:
        try:
          let updatedLogFile = getLogFile(
            CodexLogsDir, starttime, suiteName, currentTestName, $role, none int
          )
          args.add "--log-file=" & updatedLogFile
        except IOError as e:
          raiseMultiNodeSuiteError(
            "failed to start hardhat because logfile path could not be obtained: " &
              e.msg,
            e,
          )
        except OSError as e:
          raiseMultiNodeSuiteError(
            "failed to start hardhat because logfile path could not be obtained: " &
              e.msg,
            e,
          )

      let port = await nextFreePort(lastUsedHardhatPort)
      jsonRpcProviderUrl.updatePort(port)
      args.add("--port")
      args.add($port)
      lastUsedHardhatPort = port

      try:
        let node = await HardhatProcess.startNode(args, config.debugEnabled, "hardhat")
        await node.waitUntilStarted()
        trace "hardhat node started"
        return node
      except NodeProcessError as e:
        raiseMultiNodeSuiteError "hardhat node not started: " & e.msg

    proc newCodexProcess(
        roleIdx: int, conf: CodexConfig, role: Role
    ): Future[NodeProcess] {.async: (raises: [MultiNodeSuiteError, CancelledError]).} =
      let nodeIdx = running.len
      var config = conf

      if nodeIdx > accounts.len - 1:
        raiseMultiNodeSuiteError "Cannot start node at nodeIdx " & $nodeIdx &
          ", not enough eth accounts."

      let datadir = getDataDir(TestId, currentTestName, $starttime, $role, some roleIdx)

      try:
        if config.logFile.isSome or CodexLogToFile:
          try:
            let updatedLogFile = getLogFile(
              CodexLogsDir, starttime, suiteName, currentTestName, $role, some roleIdx
            )
            config.withLogFile(updatedLogFile)
          except IOError as e:
            raiseMultiNodeSuiteError(
              "failed to start " & $role &
                " because logfile path could not be obtained: " & e.msg,
              e,
            )
          except OSError as e:
            raiseMultiNodeSuiteError(
              "failed to start " & $role &
                " because logfile path could not be obtained: " & e.msg,
              e,
            )

        when CodexLogLevel != "":
          config.addCliOption("--log-level", CodexLogLevel)

        var apiPort, discPort: int
        withLock(codexPortLock):
          apiPort = await nextFreePort(lastUsedCodexApiPort + nodeIdx)
          discPort = await nextFreePort(lastUsedCodexDiscPort + nodeIdx)
          config.addCliOption("--api-port", $apiPort)
          config.addCliOption("--disc-port", $discPort)
          lastUsedCodexApiPort = apiPort
          lastUsedCodexDiscPort = discPort

        for bootstrapNode in bootstrapNodes:
          config.addCliOption("--bootstrap-node", bootstrapNode)

        config.addCliOption("--data-dir", datadir)
        config.addCliOption("--nat", "none")
        config.addCliOption("--listen-addrs", "/ip4/127.0.0.1/tcp/0")
      except CodexConfigError as e:
        raiseMultiNodeSuiteError "invalid cli option, error: " & e.msg

      try:
        let node = await CodexProcess.startNode(
          config.cliArgs, config.debugEnabled, $role & $roleIdx
        )
        await node.waitUntilStarted()
        trace "node started", nodeName = $role & $roleIdx
        return node
      except CodexConfigError as e:
        raiseMultiNodeSuiteError "failed to get cli args from config: " & e.msg, e
      except NodeProcessError as e:
        raiseMultiNodeSuiteError "node not started, error: " & e.msg, e

    proc hardhat(): HardhatProcess =
      for r in running:
        if r.role == Role.Hardhat:
          return HardhatProcess(r.node)
      return nil

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

    proc startHardhatNode(
        config: HardhatConfig
    ): Future[NodeProcess] {.async: (raises: [MultiNodeSuiteError, CancelledError]).} =
      return await newHardhatProcess(config, Role.Hardhat)

    proc startClientNode(conf: CodexConfig): Future[NodeProcess] {.async.} =
      let clientIdx = clients().len
      var config = conf
      config.addCliOption(StartUpCmd.persistence, "--eth-provider", jsonRpcProviderUrl)
      config.addCliOption(
        StartUpCmd.persistence, "--eth-account", $accounts[running.len]
      )
      return await newCodexProcess(clientIdx, config, Role.Client)

    proc startProviderNode(
        conf: CodexConfig
    ): Future[NodeProcess] {.async: (raises: [MultiNodeSuiteError, CancelledError]).} =
      try:
        let providerIdx = providers().len
        var config = conf
        config.addCliOption(
          StartUpCmd.persistence, "--eth-provider", jsonRpcProviderUrl
        )
        config.addCliOption(
          StartUpCmd.persistence, "--eth-account", $accounts[running.len]
        )
        config.addCliOption(
          PersistenceCmd.prover, "--circom-r1cs",
          "vendor/codex-contracts-eth/verifier/networks/hardhat/proof_main.r1cs",
        )
        config.addCliOption(
          PersistenceCmd.prover, "--circom-wasm",
          "vendor/codex-contracts-eth/verifier/networks/hardhat/proof_main.wasm",
        )
        config.addCliOption(
          PersistenceCmd.prover, "--circom-zkey",
          "vendor/codex-contracts-eth/verifier/networks/hardhat/proof_main.zkey",
        )

        return await newCodexProcess(providerIdx, config, Role.Provider)
      except CodexConfigError as exc:
        raiseMultiNodeSuiteError "Failed to start codex node, error adding cli options: " &
          exc.msg, exc

    proc startValidatorNode(
        conf: CodexConfig
    ): Future[NodeProcess] {.async: (raises: [MultiNodeSuiteError, CancelledError]).} =
      try:
        let validatorIdx = validators().len
        var config = conf
        config.addCliOption(
          StartUpCmd.persistence, "--eth-provider", jsonRpcProviderUrl
        )
        config.addCliOption(
          StartUpCmd.persistence, "--eth-account", $accounts[running.len]
        )
        config.addCliOption(StartUpCmd.persistence, "--validator")

        return await newCodexProcess(validatorIdx, config, Role.Validator)
      except CodexConfigError as e:
        raiseMultiNodeSuiteError "Failed to start validator node, error adding cli options: " &
          e.msg, e

    proc teardownImpl() {.async: (raises: []).} =
      trace "Tearing down test", suite = suiteName, test = currentTestName
      for nodes in @[validators(), clients(), providers()]:
        for node in nodes:
          await node.stop() # also stops rest client
          try:
            node.removeDataDir()
          except CodexProcessError as e:
            error "Failed to remove data dir during teardown", error = e.msg

      # if hardhat was started in the test, kill the node
      # otherwise revert the snapshot taken in the test setup
      let hardhat = hardhat()
      if not hardhat.isNil:
        await hardhat.stop()
      else:
        try:
          discard await noCancel send(ethProvider, "evm_revert", @[snapshot])
        except ProviderError as e:
          error "Failed to revert hardhat state during teardown", error = e.msg

      running = @[]

    template failAndTeardownOnError(message: string, tryBody: untyped) =
      try:
        tryBody
      except CancelledError as e:
        await teardownImpl()
        when declared(teardownAllIMPL):
          teardownAllIMPL()
        fail()
        quit(1)
      except CatchableError as er:
        fatal message, error = er.msg
        echo "[FATAL] ", message, ": ", er.msg
        await teardownImpl()
        when declared(teardownAllIMPL):
          teardownAllIMPL()
        fail()
        quit(1)

    proc updateBootstrapNodes(
        node: CodexProcess
    ): Future[void] {.async: (raises: [MultiNodeSuiteError]).} =
      try:
        without ninfo =? await node.client.info():
          # raise CatchableError instead of Defect (with .get or !) so we
          # can gracefully shutdown and prevent zombies
          raiseMultiNodeSuiteError "Failed to get node info"
        bootstrapNodes.add ninfo["spr"].getStr()
      except CatchableError as e:
        raiseMultiNodeSuiteError "Failed to get node info: " & e.msg, e

    setupAll:
      # When this file is run with `-d:chronicles_sinks=textlines[file]`, we
      # need to set the log file path at runtime, otherwise chronicles didn't seem to
      # create a log file even when using an absolute path
      when defaultChroniclesStream.outputs is (FileOutput,) and CodexLogsDir.len > 0:
        let logFile =
          CodexLogsDir / sanitize(getAppFilename().extractFilename & ".chronicles.log")
        let success = defaultChroniclesStream.outputs[0].open(logFile, fmAppend)
        doAssert success, "Failed to open log file: " & logFile

    setup:
      trace "Setting up test", suite = suiteName, test = currentTestName, nodeConfigs

      if var conf =? nodeConfigs.hardhat:
        try:
          let node = await noCancel startHardhatNode(conf)
          running.add RunningNode(role: Role.Hardhat, node: node)
        except CatchableError as e: # CancelledError not raised due to noCancel
          echo "failed to start hardhat node"
          fail()
          quit(1)

      try:
        # Workaround for https://github.com/NomicFoundation/hardhat/issues/2053
        # Do not use websockets, but use http and polling to stop subscriptions
        # from being removed after 5 minutes
        ethProvider = JsonRpcProvider.new(
          jsonRpcProviderUrl, pollingInterval = chronos.milliseconds(1000)
        )
        # if hardhat was NOT started by the test, take a snapshot so it can be
        # reverted in the test teardown
        if nodeConfigs.hardhat.isNone:
          snapshot = await send(ethProvider, "evm_snapshot")
        accounts = await ethProvider.listAccounts()
      except CancelledError as e:
        raise e
      except CatchableError as e:
        echo "Hardhat not running. Run hardhat manually " &
          "before executing tests, or include a " & "HardhatConfig in the test setup."
        fail()
        quit(1)

      if var clients =? nodeConfigs.clients:
        failAndTeardownOnError "failed to start client nodes":
          for config in clients.configs:
            let node = await startClientNode(config)
            running.add RunningNode(role: Role.Client, node: node)
            await CodexProcess(node).updateBootstrapNodes()

      if var providers =? nodeConfigs.providers:
        failAndTeardownOnError "failed to start provider nodes":
          for config in providers.configs.mitems:
            let node = await startProviderNode(config)
            running.add RunningNode(role: Role.Provider, node: node)
            await CodexProcess(node).updateBootstrapNodes()

      if var validators =? nodeConfigs.validators:
        failAndTeardownOnError "failed to start validator nodes":
          for config in validators.configs.mitems:
            let node = await startValidatorNode(config)
            running.add RunningNode(role: Role.Validator, node: node)

      # ensure that we have a recent block with a fresh timestamp
      discard await send(ethProvider, "evm_mine")

      trace "Starting test", suite = suiteName, test = currentTestName

    teardown:
      await teardownImpl()
      trace "Test completed", suite = suiteName, test = currentTestName

    body
