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

proc checkNatReachability*(client: StorageClient, reachability: string) {.async.} =
  check eventuallySafe(
    (await client.natReachability()).get() == reachability,
    timeout = RelayTimeout,
    pollInterval = PollInterval,
  )

proc checkRelayIsRunning*(client: StorageClient, isRunning: bool) {.async.} =
  check eventuallySafe(
    (await client.natRelayRunning()).get() == isRunning,
    timeout = RelayTimeout,
    pollInterval = PollInterval,
  )

  check eventuallySafe(
    block:
      let addrs = (await client.info()).get["addrs"].getElems.mapIt(it.getStr)
      addrs.anyIt("p2p-circuit" in it) == isRunning,
    timeout = RelayTimeout,
    pollInterval = PollInterval,
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
    await node2.client.checkNatReachability("Reachable")
    await node2.client.checkRelayIsRunning(false)

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
    await node2.client.checkNatReachability("Reachable")
    await node2.client.checkRelayIsRunning(false)

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
    await node2.client.checkNatReachability("NotReachable")
    await node2.client.checkRelayIsRunning(true)

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

    await node2.client.checkNatReachability("NotReachable")
    await node2.client.checkRelayIsRunning(true)

    check (await node2.client.setNatFiltering("endpoint-independent")).isOk

    await node2.client.checkNatReachability("Reachable")
    await node2.client.checkRelayIsRunning(false)

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

    await node2.client.checkNatReachability("Reachable")
    await node2.client.checkRelayIsRunning(false)

    check (await node2.client.setNatFiltering("address-and-port-dependent")).isOk

    await node2.client.checkNatReachability("NotReachable")
    await node2.client.checkRelayIsRunning(true)

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

    await node2.client.checkNatReachability("NotReachable")
    await node3.client.checkNatReachability("NotReachable")
    await node2.client.checkRelayIsRunning(true)
    await node3.client.checkRelayIsRunning(true)
