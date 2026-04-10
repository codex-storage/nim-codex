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
      .withLogFile()
      .withLogLevel("DEBUG").some
  )

  # Reminder: multinodesuite setup the first node as bootstrap node
  test "node is reachable when using bootstrap node on same network", natConfig:
    let node1 = clients()[0]
    let node2 = clients()[1]

    # Temporary
    # DHT exposes only UDP information
    # So we force temporary by connection the 2 node together
    # to update the autonat reachability
    let info = await node2.client.info()

    check not info.isErr

    await node1.client.connectPeer(
      info.get()["id"].getStr(), info.get()["addrs"].getElems().mapIt(it.getStr())
    )

    check eventuallySafe(
      (await node1.client.natReachability()).get() == "Reachable",
      timeout = 30_000,
      pollInterval = 500,
    )
