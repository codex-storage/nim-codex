import std/os
import std/httpclient
import std/strutils
from std/net import TimeoutError

import pkg/chronos
import ../ethertest
import ./nodes

ethersuite "Node block expiration tests":
  var node: NodeProcess
  var baseurl: string

  let dataDir = getTempDir() / "Codex1"
  let content = "test file content"

  setup:
    baseurl = "http://localhost:8080/api/codex/v1"

  teardown:
    node.stop()

    dataDir.removeDir()

  proc startTestNode(ttlSeconds: int) =
    node = startNode([
      "--api-port=8080",
      "--data-dir=" & dataDir,
      "--nat=127.0.0.1",
      "--listen-addrs=/ip4/127.0.0.1/tcp/0",
      "--disc-ip=127.0.0.1",
      "--disc-port=8090",
      "--default-ttl=" & $ttlSeconds,
      "--maintenance-interval=1"
    ], debug = false)
    node.waitUntilStarted()

  proc uploadTestFile(): string =
    let client = newHttpClient()
    let uploadUrl = baseurl & "/data"
    let uploadResponse = client.post(uploadUrl, content)
    check uploadResponse.status == "200 OK"
    client.close()
    uploadResponse.body

  proc downloadTestFile(contentId: string, local = false): Response =
    let client = newHttpClient(timeout=3000)
    let downloadUrl = baseurl & "/data/" &
      contentId & (if local: "" else: "/network")

    let content = client.get(downloadUrl)
    client.close()
    content

  proc hasFile(contentId: string): bool =
    let client = newHttpClient(timeout=3000)
    let dataLocalUrl = baseurl & "/data/" & contentId
    let content = client.get(dataLocalUrl)
    client.close()
    content.code == Http200

  test "node retains not-expired file":
    startTestNode(ttlSeconds = 10)

    let contentId = uploadTestFile()

    await sleepAsync(2.seconds)

    let response = downloadTestFile(contentId, local = true)
    check:
      hasFile(contentId)
      response.status == "200 OK"
      response.body == content

  test "node deletes expired file":
    startTestNode(ttlSeconds = 2)

    let contentId = uploadTestFile()

    await sleepAsync(1.seconds)

    # check:
    #   hasFile(contentId)

    await sleepAsync(3.seconds)

    check:
      not hasFile(contentId)
      downloadTestFile(contentId, local = true).code == Http404
