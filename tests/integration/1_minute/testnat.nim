import std/json
import std/options
import std/sequtils
import pkg/chronos
import pkg/questionable/results

import ../multinodes
import ../storageclient
import ../storageconfig

multinodesuite "AutoNAT integration":
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

  # Reminder: multinodesuite setup the first node as bootstrap node
  test "node is reachable when using bootstrap node on same network", natConfig:
    let node1 = clients()[0]
    let node2 = clients()[1]

    check eventuallySafe(
      (await node2.client.natReachability()).get() == "Reachable",
      timeout = 30_000,
      pollInterval = 500,
    )
