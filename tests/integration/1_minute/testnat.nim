import std/options
import pkg/chronos
import pkg/questionable/results

import ../multinodes
import ../storageclient
import ../storageconfig
import ../nathelper

export nathelper

const DetectionTimeout = 15_000

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
    await node2.client.checkReachable()

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
    await node2.client.checkReachable()

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
    await node2.client.checkNotReachable()

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

    await node2.client.checkNotReachable()

    check (await node2.client.setNatFiltering("endpoint-independent")).isOk

    await node2.client.checkReachable()

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

    await node2.client.checkReachable()

    check (await node2.client.setNatFiltering("address-and-port-dependent")).isOk

    await node2.client.checkNotReachable()

  let doubleNatConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(0)
      .withNatSimulation(idx = 1, "double-nat")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(5.seconds)
      .withNatMaxQueueSize(1).some
  )
  test "node behind double NAT is detected as not reachable and starts relay",
    doubleNatConfig:
    let node2 = clients()[1]
    await node2.client.checkNotReachable()

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

    await node2.client.checkNotReachable()
    await node3.client.checkNotReachable()
