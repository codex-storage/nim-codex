## NAT pcp scenario — node behind a real NAT becomes Reachable by mapping its
## port over PCP.
##
## Same shape as the upnp test, but miniupnpd has PCP enabled and the node maps
## its TCP/UDP ports via PCP (libplum's preferred protocol), which installs a real
## DNAT on the router. AutoNAT's dial-back then reaches the node, so it is
## detected Reachable with an active PCP mapping — no relay.
##
## Requires podman-compose and the scenario image:
##   podman build -t localhost/storage-nat -f tests/integration/nat/Dockerfile .

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

const
  detectTimeout = 300_000 # ms
  pollInterval = 5_000 # ms

proc announcesDirectAddr(info: JsonNode): bool =
  ## A reachable node announces at least one direct (non-circuit) address.
  info{"announceAddresses"}.getElems.anyIt("p2p-circuit" notin it.getStr)

asyncchecksuite "NAT pcp":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    nodeApiUrl = "http://127.0.0.1:18083/api/storage/v1"
    suiteName = "NAT pcp"
    testName = "node behind NAT maps its port over PCP and is Reachable"
    services = ["router", "bootstrap", "node"]
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
    # Reachable is the settling signal: wait for it, then assert each expected
    # property separately so a failure points at the exact condition.
    check eventuallySafe(
      block:
        var reachable = false
        try:
          let info = await client.info()
          reachable =
            info.isOk and info.get{"nat"}{"reachability"}.getStr == "Reachable"
        except HttpError:
          discard # B's API is not up yet, keep polling
        reachable,
      timeout = detectTimeout,
      pollInterval = pollInterval,
    )

    let info = (await client.info()).get
    let nat = info{"nat"}
    check nat{"reachability"}.getStr == "Reachable"
    check nat{"relayRunning"}.getBool == false
    check nat{"portMapping"}.getStr == "pcp"
    check info.announcesDirectAddr()
