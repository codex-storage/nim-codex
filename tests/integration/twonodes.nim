import std/os
import std/macros
import std/json
import std/httpclient
import ../ethertest
import ./nodes

export ethertest
export httpclient

template twonodessuite*(name: string, debug1, debug2: bool, body) =

  ethersuite name:

    var node1 {.inject, used.}: NodeProcess
    var node2 {.inject, used.}: NodeProcess
    var client {.inject, used.}: HttpClient
    var baseurl1 {.inject, used.}: string
    var baseurl2 {.inject, used.}: string

    let dataDir1 = getTempDir() / "Codex1"
    let dataDir2 = getTempDir() / "Codex2"

    setup:
      baseurl1 = "http://localhost:8080/api/codex/v1"
      baseurl2 = "http://localhost:8081/api/codex/v1"
      client = newHttpClient()

      node1 = startNode([
        "--api-port=8080",
        "--data-dir=" & dataDir1,
        "--nat=127.0.0.1",
        "--disc-ip=127.0.0.1",
        "--disc-port=8090",
        "--persistence",
        "--eth-account=" & $accounts[0]
      ], debug = debug1)

      let bootstrap = client
        .getContent(baseurl1 & "/debug/info")
        .parseJson()["spr"].getStr()

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
      client.close()

      node1.stop()
      node2.stop()

      removeDir(dataDir1)
      removeDir(dataDir2)

    body
