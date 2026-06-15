## NAT reachable scenario — node behind a real NAT is Reachable because the
## router forwards its port.
##
## Same shape as the not-reachable test: compose.yml brings up a real NAT
## topology, but the router has a static inbound port-forward (DNAT) to the node.
## AutoNAT's dial-back reaches the node, so it is detected Reachable (no relay) —
## a manual port-forward / endpoint-independent NAT, no miniupnpd.
##
## Requires podman-compose and the scenario image:
##   podman build -t localhost/storage-nat:reachable \
##     -f tests/integration/nat/reachable/Dockerfile .

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesDirectAddr(info: JsonNode): bool =
  ## A reachable node announces at least one direct (non-circuit) address.
  info{"announceAddresses"}.getElems.anyIt("p2p-circuit" notin it.getStr)

asyncchecksuite "NAT reachable":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    nodeApiUrl = "http://127.0.0.1:18081/api/storage/v1"
    suiteName = "NAT reachable"
    testName = "node behind NAT with a forwarded port is Reachable"
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
    check eventuallyInfo(client, info{"nat"}{"reachability"}.getStr == "Reachable")

    let info = (await client.info()).get
    let nat = info{"nat"}
    check nat{"reachability"}.getStr == "Reachable"
    check nat{"relayRunning"}.getBool == false
    check info.announcesDirectAddr()
    let announced = info{"announceAddresses"}.getElems.mapIt(it.getStr)
    check announced.anyIt(("/ip4/" & routerWanIp & "/tcp/8070") in it)
    # public forwarded address
    # a reachable node announces its UDP address to the DHT routing record
    check info{"dhtAddresses"}.getElems.len > 0
