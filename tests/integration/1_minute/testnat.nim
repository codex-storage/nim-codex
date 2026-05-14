import std/json
import std/options
import std/sequtils
import pkg/chronos
import pkg/questionable/results

import ../multinodes
import ../storageclient
import ../storageconfig

const
  DetectionTimeout = 15_000
  RelayTimeout = 30_000
  PollInterval = 1_000

proc checkNatStatus*(
    client: StorageClient, reachability: string, relayRunning: bool, clientMode: bool
) {.async.} =
  check eventuallySafe(
    block:
      let info = (await client.info()).get
      let nat = info["nat"]
      let addrs = info["addrs"].getElems.mapIt(it.getStr)
      nat["reachability"].getStr() == reachability and
        nat["clientMode"].getBool() == clientMode and
        nat["relayRunning"].getBool() == relayRunning and
        addrs.anyIt("p2p-circuit" in it) == relayRunning,
    timeout = RelayTimeout,
    pollInterval = PollInterval,
  )

proc checkNatStatus*(client: StorageClient, reachability: string) {.async.} =
  let notReachable = reachability == "NotReachable"
  await client.checkNatStatus(
    reachability, relayRunning = notReachable, clientMode = notReachable
  )

# Reminder: multinodesuite setup the first node as bootstrap node
multinodesuite "AutoNAT detection":
  let natConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(10.seconds)
      .withNatMaxQueueSize(1).some
  )
  test "node is reachable when using bootstrap node on same network", natConfig:
    let node2 = clients()[1]
    await node2.client.checkNatStatus("Reachable")

  let endpointIndependentConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatSimulation(idx = 1, "endpoint-independent")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(10.seconds)
      .withNatMaxQueueSize(1).some
  )
  # EIF = Endpoint Independent Filtering
  test "node with simulated EIF nat is detected as reachable", endpointIndependentConfig:
    let node2 = clients()[1]
    await node2.client.checkNatStatus("Reachable")

  let autonatConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatSimulation(idx = 1, "address-and-port-dependent")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(10.seconds)
      .withNatMaxQueueSize(1).some
  )
  # APDF = Address and Port-Dependent Filtering
  test "node with simulated APDF nat is detected as not reachable and starts relay",
    autonatConfig:
    let node2 = clients()[1]
    await node2.client.checkNatStatus("NotReachable")

  let transitionConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatSimulation(idx = 1, "address-and-port-dependent")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(5.seconds)
      .withNatMaxQueueSize(1).some
  )
  # APDF = Address and Port-Dependent Filtering
  # EIF = Endpoint Independent Filtering
  test "node with simulated APDF nat recovers to reachable and stops relay when nat switches to EIF nat",
    transitionConfig:
    let node2 = clients()[1]

    await node2.client.checkNatStatus("NotReachable")

    check (await node2.client.setNatFiltering("endpoint-independent")).isOk

    await node2.client.checkNatStatus("Reachable")

  let natToSimConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatSimulation(idx = 1, "endpoint-independent")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(5.seconds)
      .withNatMaxQueueSize(1).some
  )
  # APDF = Address and Port-Dependent Filtering
  test "reachable node becomes not reachable and starts relay when nat switches to APDF nat",
    natToSimConfig:
    let node2 = clients()[1]

    await node2.client.checkNatStatus("Reachable")

    check (await node2.client.setNatFiltering("address-and-port-dependent")).isOk

    await node2.client.checkNatStatus("NotReachable")

  let multiNatConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 3)
      .withRelay(0)
      .withNatSimulation(idx = 1, "address-and-port-dependent")
      .withNatSimulation(idx = 2, "address-and-port-dependent")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(5.seconds)
      .withNatMaxQueueSize(1).some
  )
  # APDF = Address and Port-Dependent Filtering
  test "two nodes with simulated APDF nat starts relay through the same relay node",
    multiNatConfig:
    let node2 = clients()[1]
    let node3 = clients()[2]

    await node2.client.checkNatStatus("NotReachable")
    await node3.client.checkNatStatus("NotReachable")
