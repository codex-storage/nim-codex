import std/[json, strutils, sequtils]
import pkg/chronos
import pkg/questionable/results

import ../integration/multinodes
import ../integration/storageclient
import ../integration/storageconfig

import ../integration/nathelper

multinodesuite "AutoNAT PCP port mapping":
  let pcpConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatSimulation(idx = 1, "address-and-port-dependent")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(10.seconds)
      .withNatMaxQueueSize(1).some
  )

  test "node behind NAT maps ports via PCP and exposes mapping in debug info", pcpConfig:
    let node2 = clients()[1]

    await node2.client.checkNotReachable(relayRunning = false)

    check eventuallySafe(
      block:
        let res = await node2.client.natPortMapping()
        res.isOk and res.get == "pcp",
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
      .withNatScheduleInterval(10.seconds)
      # Increase the max queue to trigger the AutoNat 2 times
      .withNatMaxQueueSize(2).some
  )

  test "node behind double NAT falls back to relay after PCP mapping does not help",
    relayFallbackConfig:
    let node2 = clients()[1]

    await node2.client.checkNotReachable(relayRunning = false)

    check eventuallySafe(
      block:
        let res = await node2.client.natPortMapping()
        res.isOk and res.get == "pcp",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    await node2.client.checkNotReachable()

  test "reachable node downloads content uploaded by node behind NAT after PCP mapping",
    pcpConfig:
    let node1 = clients()[0]
    let node2 = clients()[1]

    check eventuallySafe(
      block:
        let res = await node2.client.natPortMapping()
        res.isOk and res.get == "pcp",
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
