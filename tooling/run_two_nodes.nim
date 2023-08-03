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

var node1 {.inject, used.}: NodeProcess
var node2 {.inject, used.}: NodeProcess
var client1 {.inject, used.}: CodexClient
var client2 {.inject, used.}: CodexClient
var account1 {.inject, used.}: Address
var account2 {.inject, used.}: Address

let dataDir1 = getTempDir() / "Codex1"
let dataDir2 = getTempDir() / "Codex2"

var provider {.inject, used.}: JsonRpcProvider
var accounts {.inject, used.}: seq[Address]
var snapshot: JsonNode


proc ethStart*() {.async.} =
  {.cast(gcsafe).}:
    provider = JsonRpcProvider.new("ws://localhost:8545")
    snapshot = await send(provider, "evm_snapshot")
    accounts = await provider.listAccounts()

proc ethEnd() {.async.} =
  {.cast(gcsafe).}:
    discard await send(provider, "evm_revert", @[snapshot])

proc twonodessuite*(name: string, debug1, debug2: string) =

    waitFor ethStart()

    client1 = CodexClient.new("http://localhost:8080/api/codex/v1")
    client2 = CodexClient.new("http://localhost:8081/api/codex/v1")
    account1 = accounts[0]
    account2 = accounts[1]

    var node1Args = @[
      "--api-port=8080",
      "--data-dir=" & dataDir1,
      "--nat=127.0.0.1",
      "--disc-ip=127.0.0.1",
      "--disc-port=8090",
      "--persistence",
      "--eth-account=" & $account1
    ]

    if debug1 != "true" and debug1 != "false":
      node1Args.add("--log-level=" & debug1)

    node1 = startNode(node1Args, debug = debug1)

    let bootstrap = client1.info()["spr"].getStr()

    var node2Args = @[
      "--api-port=8081",
      "--data-dir=" & dataDir2,
      "--nat=127.0.0.1",
      "--disc-ip=127.0.0.1",
      "--disc-port=8091",
      "--bootstrap-node=" & bootstrap,
      "--persistence",
      "--eth-account=" & $account2
    ]

    if debug2 != "true" and debug2 != "false":
      node2Args.add("--log-level=" & debug2)

    node2 = startNode(node2Args, debug = debug2)

proc stop() =
  client1.close()
  client2.close()

  node1.stop()
  node2.stop()

  removeDir(dataDir1)
  removeDir(dataDir2)

  waitFor ethEnd()

proc ctrlc() {.noconv.} =
  echo "Shutting down after having received SIGTERM"
  echo "Stopping twonodes"
  stop()

setControlCHook(ctrlc)

try:
  let res = waitFor execCommand("nim build")
  assert res == 0
  twonodessuite("test", "true", "false")
  runForever()
finally:
  stop()

