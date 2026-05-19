import std/[json, strutils, sequtils]
import pkg/chronos
import pkg/questionable/results

import ../integration/multinodes
import ../integration/storageclient
import ../integration/storageconfig

import ../integration/nathelper

const DetectionTimeout = 15_000

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
    let node2 = clients()[1]

    await node2.client.checkNatStatus(
      "NotReachable", relayRunning = false, clientMode = true
    )

    check eventuallySafe(
      block:
        let res = await node2.client.natPortMapping()
        res.isOk and res.get == "upnp",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    await node2.client.checkNatStatus(
      "NotReachable", relayRunning = false, clientMode = true
    )

    let announceAddrs =
      (await node2.client.info()).get["announceAddresses"].getElems.mapIt(it.getStr)
    let tcpAddr = announceAddrs.filterIt(it.startsWith("/ip4/") and "/tcp/" in it)
    check tcpAddr.len > 0

    await node2.stop()
