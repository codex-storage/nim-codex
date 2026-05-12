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

# Reminder: multinodesuite setup the first node as bootstrap node
multinodesuite "AutoNAT detection":
  let natConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(10.seconds)
      .withNatMaxQueueSize(1)
      # .withLogFile()
      # .withLogLevel("DEBUG")
      .some
  )
  test "node is reachable when using bootstrap node on same network", natConfig:
    let node2 = clients()[1]

    check eventuallySafe(
      (await node2.client.natReachability()).get() == "Reachable",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check eventuallySafe(
      not (await node2.client.natRelayRunning()).get(),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

  let autonatConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(idx = 0)
      .withNatSimulation(idx = 1)
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(10.seconds)
      .withNatMaxQueueSize(1)
      # .withLogLevel("DEBUG")
      # .debug()
      # .withLogFile()
      .some
  )
  # node2 is behind simulated NAT: AutoNAT peers try to dial back but are blocked.
  test "nat node is detected as not reachable and starts relay", autonatConfig:
    let node2 = clients()[1]

    check eventuallySafe(
      (await node2.client.natReachability()).get() == "NotReachable",
      timeout = DetectionTimeout,
      pollInterval = PollInterval,
    )

    check eventuallySafe(
      (await node2.client.natRelayRunning()).get(),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check eventuallySafe(
      block:
        let addrs = (await node2.client.info()).get["addrs"].getElems.mapIt(it.getStr)
        addrs.anyIt("p2p-circuit" in it),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

  let transitionConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(idx = 0)
      .withNatSimulation(idx = 1)
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(5.seconds)
      .withNatMaxQueueSize(1).some
  )
  # node2 starts behind simulated NAT (NotReachable + relay), then NAT is lifted
  # and AutoNAT detects Reachable on the next scheduled check.
  test "nat node recovers to reachable when nat is lifted", transitionConfig:
    let node2 = clients()[1]

    check eventuallySafe(
      (await node2.client.natReachability()).get() == "NotReachable",
      timeout = DetectionTimeout,
      pollInterval = PollInterval,
    )

    check eventuallySafe(
      (await node2.client.natRelayRunning()).get(),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check eventuallySafe(
      block:
        let addrs = (await node2.client.info()).get["addrs"].getElems.mapIt(it.getStr)
        addrs.anyIt("p2p-circuit" in it),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check (await node2.client.setNatFiltering("endpoint-independent")).isOk

    check eventuallySafe(
      (await node2.client.natReachability()).get() == "Reachable",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check eventuallySafe(
      not (await node2.client.natRelayRunning()).get(),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

  let natToSimConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withRelay(idx = 0)
      .withNatSimulation(idx = 1, "endpoint-independent")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(5.seconds)
      .withNatMaxQueueSize(1).some
  )
  # node2 starts reachable (endpoint-independent NAT sim = pass-through),
  # then NAT is tightened to block dial-backs and AutoNAT detects NotReachable.
  test "reachable node becomes not reachable when nat is applied", natToSimConfig:
    let node2 = clients()[1]

    check eventuallySafe(
      (await node2.client.natReachability()).get() == "Reachable",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check eventuallySafe(
      not (await node2.client.natRelayRunning()).get(),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check (await node2.client.setNatFiltering("address-and-port-dependent")).isOk

    check eventuallySafe(
      (await node2.client.natReachability()).get() == "NotReachable",
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check eventuallySafe(
      (await node2.client.natRelayRunning()).get(),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )
