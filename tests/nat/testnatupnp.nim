import std/[json, strutils, sequtils]
import pkg/chronos
import pkg/questionable/results

import ../integration/multinodes
import ../integration/storageclient
import ../integration/storageconfig

import ../integration/nathelper

multinodesuite "AutoNAT UPnP port mapping":
  let upnpConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatSimulation(idx = 1, "address-and-port-dependent")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(NatScheduleInterval)
      .withNatMaxQueueSize(1).some
  )

  test "node behind NAT maps ports via UPnP and exposes mapping in debug info",
    upnpConfig:
    let node2 = clients()[1]

    await node2.client.checkNotReachable(relayRunning = false)

    check eventuallySafe(
      block:
        let res = await node2.client.natPortMapping()
        res.isOk and res.get == "upnp",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    await node2.client.checkReachable()

    await node2.stop()

  let relayFallbackConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatSimulation(idx = 1, "double-nat")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(NatScheduleInterval)
      # Increase the max queue to trigger the AutoNat 2 times
      .withNatMaxQueueSize(2).some
  )

  test "node behind double NAT falls back to relay after UPnP mapping does not help",
    relayFallbackConfig:
    let node2 = clients()[1]

    await node2.client.checkNotReachable(relayRunning = false)

    check eventuallySafe(
      block:
        let res = await node2.client.natPortMapping()
        res.isOk and res.get == "upnp",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    # Wait for next Autonat iteration
    await sleepAsync(6.seconds)

    await node2.client.checkNotReachable()

  test "reachable node downloads content uploaded by node behind NAT after UPnP mapping",
    upnpConfig:
    let node1 = clients()[0]
    let node2 = clients()[1]

    check eventuallySafe(
      block:
        let res = await node2.client.natPortMapping()
        res.isOk and res.get == "upnp",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    let content = "content uploaded by nat node"
    let cid = (await node2.client.upload(content)).get

    check eventuallySafe(
      (await node1.client.download(cid)).isOk,
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check (await node1.client.download(cid)).get == content
