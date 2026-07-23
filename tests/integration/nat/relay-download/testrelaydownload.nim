## NAT relay-download scenario. See README.md.

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesCircuitAddr(info: JsonNode): bool =
  ## A node behind the relay announces its circuit (p2p-circuit) address.
  info{"providerAddresses"}.getElems.anyIt("p2p-circuit" in it.getStr)

asyncchecksuite "NAT relay download":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    nodeApiUrl = "http://127.0.0.1:18086/api/storage/v1"
    clientApiUrl = "http://127.0.0.1:18087/api/storage/v1"
    suiteName = "NAT relay download"
    testName = "a NAT'd node behind a relay can be downloaded from"
    services = ["router", "bootstrap", "client", "node"]
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var
    nodeClient: StorageClient
    clientC: StorageClient

  setup:
    compose(composeFile, "up -d")
    nodeClient = StorageClient.new(nodeApiUrl)
    clientC = StorageClient.new(clientApiUrl)

  teardown:
    await nodeClient.close()
    await clientC.close()
    saveContainerLogs(composeFile, suiteName, testName, startTime, services)
    compose(composeFile, "down -v")

  test testName:
    # B is NotReachable and falls back to the relay, announcing its circuit address
    check eventuallyInfo(
      nodeClient,
      info{"nat"}{"reachability"}.getStr == "NotReachable" and
        info.announcesCircuitAddr(),
    )

    let info = (await nodeClient.info()).get
    # Double check B announces only its circuit address
    check info.announcesCircuitAddr()

    # C is reachable
    check eventuallyInfo(clientC, info{"nat"}{"reachability"}.getStr == "Reachable")

    # B uploads a file
    let content = "hello from behind the relay"
    let cid = (await nodeClient.upload(content)).get

    # C downloads it through the relay and gets the same content back
    let res = await clientC.download(cid)
    check res.isOk
    check res.get == content
