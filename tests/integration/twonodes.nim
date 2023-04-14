import std/os
import std/macros
import std/json
import std/httpclient
import ../ethertest
import ./codexclient
import ./nodes

export ethertest
export codexclient
export nodes

template twonodessuite*(name: string, debug1, debug2: bool, body) =

  ethersuite name:

    var node1 {.inject, used.}: NodeProcess
    var node2 {.inject, used.}: NodeProcess
    var client1 {.inject, used.}: CodexClient
    var client2 {.inject, used.}: CodexClient

    let dataDir1 = getTempDir() / "Codex1"
    let dataDir2 = getTempDir() / "Codex2"

    setup:
      client1 = CodexClient.new("http://localhost:8080/api/codex/v1")
      client2 = CodexClient.new("http://localhost:8081/api/codex/v1")

      node1 = startNode([
        "--api-port=8080",
        "--data-dir=" & dataDir1,
        "--nat=127.0.0.1",
        "--disc-ip=127.0.0.1",
        "--disc-port=8090",
        "--persistence",
        "--eth-account=" & $accounts[0]
      ], debug = debug1)

      let bootstrap = client1.info()["spr"].getStr()

      node2 = startNode([
        "--api-port=8081",
        "--data-dir=" & dataDir2,
        "--nat=127.0.0.1",
        "--disc-ip=127.0.0.1",
        "--disc-port=8091",
        "--bootstrap-node=" & bootstrap,
        "--persistence",
        "--eth-account=" & $accounts[1]
      ], debug = debug2)

    teardown:
      client1.close()
      client2.close()

      node1.stop()
      node2.stop()

      removeDir(dataDir1)
      removeDir(dataDir2)

    body

type
  Role = enum
    Client,
    Provider
  RunningNode* = ref object
    role: Role
    node: NodeProcess
    restClient: CodexClient
    datadir: string

template invalidproofsuite*(name: string, debugClient, debugProvider: bool, body) =



  ethersuite name:

    var running: seq[RunningNode]
    var bootstrap: string

    proc newNodeProcess(index: int,
                        addlOptions: seq[string],
                        debug: bool): (NodeProcess, string) =

      let datadir = getTempDir() / "Codex" & $index
      let node = startNode(@[
        "--api-port=" & $(8080 + index),
        "--data-dir=" & datadir,
        "--nat=127.0.0.1",
        "--disc-ip=127.0.0.1",
        "--disc-port=" & $(8090 + index),
        "--persistence",
        "--eth-account=" & $accounts[index]
      ].concat(addlOptions), debug = debug)
      debugEcho "started new codex node listening with rest api listening on port ", 8080 + index
      (node, datadir)

    proc newCodexClient(index: int): CodexClient =
      debugEcho "started new rest client talking to port ", 8080 + index
      CodexClient.new("http://localhost:" & $(8080 + index) & "/api/codex/v1")

    proc startClientNode() =
      let index = running.len
      let (node, datadir) = newNodeProcess(index, @[], debugClient)
      let restClient = newCodexClient(index)
      running.add RunningNode(role: Role.Client,
                              node: node,
                              restClient: restClient,
                              datadir: datadir)
      debugEcho "started client node, index ", index

    proc startProviderNode(failEveryNProofs: uint) =
      let index = running.len
      let (node, datadir) = newNodeProcess(index, @[
        "--bootstrap-node=" & bootstrap,
        "--simulate-proof-failures=" & $failEveryNProofs],
        debugProvider)
      let restClient = newCodexClient(index)
      running.add RunningNode(role: Role.Provider,
                              node: node,
                              restClient: restClient,
                              datadir: datadir)
      debugEcho "started provider node, index ", index

    proc clients(): seq[RunningNode] =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Client)

    proc providers(): seq[RunningNode] =
      running.filter(proc(r: RunningNode): bool = r.role == Role.Provider)

    setup:
      startClientNode()

      bootstrap = running[0].restClient.info()["spr"].getStr()

    teardown:
      for r in running:
        r.restClient.close()
        r.node.stop()
        removeDir(r.datadir)

    body
