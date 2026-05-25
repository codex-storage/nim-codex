import std/[json, sequtils]
import pkg/chronos
import pkg/questionable/results

import ../multinodes
import ../storageclient
import ../storageconfig
import ../nathelper

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
      .withNatScheduleInterval(NatScheduleInterval)
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
      (await natNode.client.natRelayRunning()).get(),
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    # Verify natNode advertises a relay circuit address. seed has never dialed
    # natNode, so APDF blocks any direct inbound connection from seed — the
    # only reachable address is the p2p-circuit one.
    let info = (await natNode.client.info()).get
    let addrs = info["addrs"].getElems.mapIt(it.getStr)
    check addrs.anyIt("p2p-circuit" in it)

    let content = "content seeded from nat node"
    let cid = (await natNode.client.upload(content)).get

    check eventuallySafe(
      (await seed.client.download(cid)).isOk,
      timeout = RelayTimeout,
      pollInterval = PollInterval,
    )

    check (await seed.client.download(cid)).get == content
