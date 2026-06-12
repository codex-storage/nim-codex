## NAT not-reachable scenario — node behind a real NAT falls back to relay.
##
## Requires podman-compose and the scenario image:
##   podman build -t localhost/storage-nat:not-reachable \
##     -f tests/integration/nat/not-reachable/Dockerfile .

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

const
  composeFile = currentSourcePath.parentDir / "compose.yml"
  nodeApiUrl = "http://127.0.0.1:18080/api/storage/v1"
  suiteName = "NAT not reachable"
  testName = "node behind NAT is NotReachable and falls back to relay"
  services = ["router", "bootstrap", "node"]
  detectTimeout = 300_000 # ms
  pollInterval = 5_000 # ms

proc announcesCircuitAddr(info: JsonNode): bool =
  info{"announceAddresses"}.getElems.anyIt("p2p-circuit" in it.getStr)

asyncchecksuite suiteName:
  let
    composeFile = composeFile
    nodeApiUrl = nodeApiUrl
    suiteName = suiteName
    testName = testName
    services = services
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var client: StorageClient

  setup:
    compose(composeFile, "up -d")
    client = StorageClient.new(nodeApiUrl)

  teardown:
    await client.close()
    saveContainerLogs(composeFile, suiteName, testName, startTime, services)
    compose(composeFile, "down -v")

  test testName:
    # Wait for the announcements, after the relay reservation is created.
    check eventuallySafe(
      block:
        var settled = false
        try:
          let info = await client.info()
          settled = info.isOk and info.get.announcesCircuitAddr()
        except HttpError:
          # B's API is not up yet, keep polling
          discard
        settled,
      timeout = detectTimeout,
      pollInterval = pollInterval,
    )

    let info = (await client.info()).get
    let nat = info{"nat"}
    check nat{"reachability"}.getStr == "NotReachable"
    check nat{"relayRunning"}.getBool
    check nat{"portMapping"}.getStr == "none"
    check info.announcesCircuitAddr()
