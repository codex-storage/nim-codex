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
import ../asynctest
import ../checktest

export asynctest
export codexprocess
export codexconfig
export nodeconfigs

type
  RunningNode* = ref object
    role*: Role
    node*: NodeProcess

  Role* {.pure.} = enum
    Client

  MultiNodeSuiteError = object of CatchableError

const jsonRpcProviderUrl* = "ws://localhost:8545"

proc raiseMultiNodeSuiteError(msg: string) =
  raise newException(MultiNodeSuiteError, msg)

proc nextFreePort*(startPort: int): Future[int] {.async.} =
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

proc sanitize(pathSegment: string): string =
  var sanitized = pathSegment
  for invalid in invalidFilenameChars.items:
    sanitized = sanitized.replace(invalid, '_').replace(' ', '_')
  sanitized

proc getTempDirName*(starttime: string, role: Role, roleIdx: int): string =
  getTempDir() / "Storage" / sanitize($starttime) / sanitize($role & "_" & $roleIdx)

template multinodesuite*(name: string, body: untyped) =
  asyncchecksuite name:
    var running {.inject, used.}: seq[RunningNode]
    var bootstrapNodes: seq[string]
    let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")
    var currentTestName = ""
    var nodeConfigs: NodeConfigs
    var snapshot: JsonNode

    template test(tname, startNodeConfigs, tbody) =
      currentTestName = tname
      nodeConfigs = startNodeConfigs
      test tname:
        tbody

    proc sanitize(pathSegment: string): string =
      var sanitized = pathSegment
      for invalid in invalidFilenameChars.items:
        sanitized = sanitized.replace(invalid, '_').replace(' ', '_')
      sanitized

    proc getLogFile(role: Role, index: ?int): string =
      # create log file path, format:
      # tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log

      var logDir =
        currentSourcePath.parentDir() / "logs" / sanitize($starttime & "__" & name) /
        sanitize($currentTestName)
      createDir(logDir)

      var fn = $role
      if idx =? index:
        fn &= "_" & $idx
      fn &= ".log"

      let fileName = logDir / fn
      return fileName

    proc newCodexProcess(
        roleIdx: int, conf: CodexConfig, role: Role
    ): Future[NodeProcess] {.async.} =
      let nodeIdx = running.len
      var config = conf
      let datadir = getTempDirName(starttime, role, roleIdx)

      try:
        if config.logFile.isSome:
          let updatedLogFile = getLogFile(role, some roleIdx)
          config.withLogFile(updatedLogFile)

        for bootstrapNode in bootstrapNodes:
          config.addCliOption("--bootstrap-node", bootstrapNode)
        config.addCliOption("--api-port", $await nextFreePort(8080 + nodeIdx))
        config.addCliOption("--data-dir", datadir)
        config.addCliOption("--nat", "none")
        config.addCliOption("--listen-addrs", "/ip4/127.0.0.1/tcp/0")
        config.addCliOption("--disc-port", $await nextFreePort(8090 + nodeIdx))
      except CodexConfigError as e:
        raiseMultiNodeSuiteError "invalid cli option, error: " & e.msg

      let node = await CodexProcess.startNode(
        config.cliArgs, config.debugEnabled, $role & $roleIdx
      )

      try:
        await node.waitUntilStarted()
        trace "node started", nodeName = $role & $roleIdx
      except NodeProcessError as e:
        raiseMultiNodeSuiteError "node not started, error: " & e.msg

      return node

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
          node.removeDataDir()

      running = @[]

    template failAndTeardownOnError(message: string, tryBody: untyped) =
      try:
        tryBody
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
    ): Future[void] {.async: (raises: [CatchableError]).} =
      without ninfo =? await node.client.info():
        # raise CatchableError instead of Defect (with .get or !) so we
        # can gracefully shutdown and prevent zombies
        raiseMultiNodeSuiteError "Failed to get node info"
      bootstrapNodes.add ninfo["spr"].getStr()

    setup:
      if var clients =? nodeConfigs.clients:
        failAndTeardownOnError "failed to start client nodes":
          for config in clients.configs:
            let node = await startClientNode(config)
            running.add RunningNode(role: Role.Client, node: node)
            await CodexProcess(node).updateBootstrapNodes()

    teardown:
      await teardownImpl()

    body
