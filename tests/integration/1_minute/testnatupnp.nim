import std/[envvars, json, strutils, sequtils]
import pkg/chronos
import pkg/questionable/results
import nat_traversal/miniupnpc

import ../multinodes
import ../storageclient
import ../storageconfig
import ../../../storage/utils/natutils

from ./testnat.nim import checkNatReachability, checkRelayIsRunning

const
  DetectionTimeout = 15_000
  RelayTimeout = 30_000
  PollInterval = 1_000

# Requires a real UPnP router on the network (NAT_TEST_UPNP=1)
multinodesuite "AutoNAT UPnP port mapping":
  let upnpConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatSimulation(idx = 1, "address-and-port-dependent")
      .withListenPort(idx = 1, 8102)
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(10.seconds)
      .withNatMaxQueueSize(1)
      .withLogFile()
      .withLogLevel(idx = 1, LogLevel.DEBUG).some
  )

  test "node behind NAT maps ports via UPnP and exposes mapping in debug info",
    upnpConfig:
    if getEnv("NAT_TEST_UPNP") != "1":
      skip()
      return

    let node2 = clients()[1]

    await node2.client.checkNatReachability("NotReachable")

    check eventuallySafe(
      block:
        let res = await node2.client.natPortMapping()
        res.isOk and res.get == "upnp",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    # Ideally we should find a way to test that the node is Reachable now

    await node2.client.checkRelayIsRunning(false)

    # Extract mapped TCP port from announce addresses and verify it exists on the IGD
    let announceAddrs =
      (await node2.client.info()).get["announceAddresses"].getElems.mapIt(it.getStr)
    let tcpAddr = announceAddrs.filterIt(it.startsWith("/ip4/") and "/tcp/" in it)
    check tcpAddr.len > 0

    let mappedPort = tcpAddr[0].split("/")[4]
    let device = UpnpDevice.init()
    check device.isOk
    check device.get.getSpecificPortMapping(mappedPort, UPNPProtocol.TCP).isOk

    await node2.stop()

    check device.get.getSpecificPortMapping(mappedPort, UPNPProtocol.TCP).isErr
