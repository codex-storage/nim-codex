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
