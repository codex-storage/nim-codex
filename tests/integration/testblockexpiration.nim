import std/osproc
import std/os
import std/httpclient
import std/strutils
import std/times

import pkg/chronos
import ../ethertest
import ../contracts/time
import ../codex/helpers/eventually
import ./nodes
import ./tokens

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

  proc startTestNode(blockTtlSeconds: int) =
    node = startNode([
      "--api-port=8080",
      "--data-dir=" & dataDir,
      "--nat=127.0.0.1",
      "--disc-ip=127.0.0.1",
      "--disc-port=8090",
      "--block-ttl=" & $blockTtlSeconds,
      "--block-mi=3",
      "--block-mn=10"
    ], debug = false)

  proc uploadTestFile(): string =
    let client = newHttpClient()
    let uploadUrl = baseurl & "/upload"
    let uploadResponse = client.post(uploadUrl, content)
    check uploadResponse.status == "200 OK"
    client.close()
    uploadResponse.body

  proc downloadTestFile(contentId: string): Response =
    let client = newHttpClient(timeout=3000)
    let downloadUrl = baseurl & "/download/" & contentId
    let content = client.get(downloadUrl)
    client.close()
    content

  test "node retains not-expired file":
    startTestNode(blockTtlSeconds = 60 * 60 * 1)

    let contentId = uploadTestFile()

    await sleepAsync(10 * 1000)

    let response = downloadTestFile(contentId)
    check:
      response.status == "200 OK"
      response.body == content

  test "node deletes expired file":
    startTestNode(blockTtlSeconds = 5)

    let contentId = uploadTestFile()

    await sleepAsync(10 * 1000)

    expect TimeoutError:
      discard downloadTestFile(contentId)
