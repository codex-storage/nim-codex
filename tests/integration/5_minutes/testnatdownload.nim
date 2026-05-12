import std/json
import std/sequtils
import pkg/chronos
import pkg/questionable/results

import ../multinodes
import ../storageclient
import ../storageconfig

const
  RelayTimeout = 30_000
  PollInterval = 1_000

multinodesuite "NAT download":
  let natDownloadConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 3)
      .withRelay(idx = 0)
      .withNatSimulation(idx = 2, "address-and-port-dependent")
      .withNatNumPeersToAsk(1)
      .withNatMinConfidence(0.5)
      .withNatScheduleInterval(5.seconds)
      .withNatMaxQueueSize(1).some
  )
  # APDF = Address and Port-Dependent Filtering
  test "node 3 with simulated APDF downloads content from reachable seed node 2",
    natDownloadConfig:
    let seed = clients()[1]
    let natNode = clients()[2]

    let content = "content for nat download test"
    let cid = (await seed.client.upload(content)).get

    check eventuallySafe(
      (await natNode.client.download(cid)).isOk,
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check (await natNode.client.download(cid)).get == content

  # APDF = Address and Port-Dependent Filtering
  test "reachable node 2 downloads content from node 3 with simulated APDF via relay",
    natDownloadConfig:
    let seed = clients()[1]
    let natNode = clients()[2]

    check eventuallySafe(
      block:
        let addrs = (await natNode.client.info()).get["addrs"].getElems.mapIt(it.getStr)
        addrs.anyIt("p2p-circuit" in it),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    let content = "content seeded from nat node"
    let cid = (await natNode.client.upload(content)).get

    check eventuallySafe(
      (await seed.client.download(cid)).isOk,
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check (await seed.client.download(cid)).get == content
