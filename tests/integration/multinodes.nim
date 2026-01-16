import std/httpclient
import std/os
import std/sequtils
import std/strutils
import std/sugar
import std/times
import pkg/codex/conf
import pkg/codex/logutils
import pkg/chronos/transports/stream
import pkg/questionable
import ./codexconfig
import ./codexprocess
import ./nodeconfigs
import ./utils
import ../asynctest
import ../checktest

export asynctest
export codexprocess
export codexconfig
export nodeconfigs

{.push raises: [].}

type
  RunningNode* = ref object
    role*: Role
    node*: NodeProcess

  Role* {.pure.} = enum
    Client

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

proc sanitize(pathSegment: string): string =
  var sanitized = pathSegment
  for invalid in invalidFilenameChars.items:
    sanitized = sanitized.replace(invalid, '_').replace(' ', '_')
  sanitized

proc getTempDirName*(starttime: string, role: Role, roleIdx: int): string =
  getTempDir() / "Storage" / sanitize($starttime) / sanitize($role & "_" & $roleIdx)

template multinodesuite*(suiteName: string, body: untyped) =
  asyncchecksuite suiteName:
    var running {.inject, used.}: seq[RunningNode]
    var bootstrapNodes: seq[string]
    let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")
    var currentTestName = ""
    var nodeConfigs: NodeConfigs
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

    proc newCodexProcess(
        roleIdx: int, conf: CodexConfig, role: Role
    ): Future[NodeProcess] {.async: (raises: [MultiNodeSuiteError, CancelledError]).} =
      let nodeIdx = running.len
      var config = conf
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

    proc clients(): seq[CodexProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Client:
            CodexProcess(r.node)

    proc startClientNode(conf: CodexConfig): Future[NodeProcess] {.async.} =
      let clientIdx = clients().len
      return await newCodexProcess(clientIdx, conf, Role.Client)

    proc teardownImpl() {.async.} =
      for nodes in @[clients()]:
        for node in nodes:
          await node.stop() # also stops rest client
          try:
            node.removeDataDir()
          except CodexProcessError as e:
            error "Failed to remove data dir during teardown", error = e.msg

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
      if var clients =? nodeConfigs.clients:
        failAndTeardownOnError "failed to start client nodes":
          for config in clients.configs:
            let node = await startClientNode(config)
            running.add RunningNode(role: Role.Client, node: node)
            await CodexProcess(node).updateBootstrapNodes()

    teardown:
      await teardownImpl()
      trace "Test completed", suite = suiteName, test = currentTestName

    body
