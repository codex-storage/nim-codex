import std/sequtils
import std/sets

import pkg/chronos
import pkg/taskpools
import pkg/libp2p
import pkg/libp2p/errors

import pkg/codex/discovery
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/blockexchange
import pkg/codex/systemclock
import pkg/codex/nat
import pkg/codex/utils/natutils
import pkg/codex/utils/safeasynciter
import pkg/codex/merkletree
import pkg/codex/manifest

import pkg/codex/node

import ./datasetutils
import ./mockdiscovery
import ../examples
import ../../helpers

proc nextFreePort*(startPort: int): Future[int] {.async.} =
  proc client(server: StreamServer, transp: StreamTransport) {.async: (raises: []).} =
    await transp.closeWait()

  var port = startPort
  while true:
    try:
      let host = initTAddress("127.0.0.1", port)
      var server = createStreamServer(host, client, {ReuseAddr})
      await server.closeWait()
      return port
    except TransportOsError:
      inc port

type
  NodesComponents* = object
    switch*: Switch
    blockDiscovery*: Discovery
    network*: BlockExcNetwork
    localStore*: BlockStore
    peerStore*: PeerCtxStore
    pendingBlocks*: PendingBlocksManager
    discovery*: DiscoveryEngine
    engine*: BlockExcEngine
    networkStore*: NetworkStore
    node*: CodexNodeRef = nil
    tempDbs*: seq[TempLevelDb] = @[]

  NodesCluster* = ref object
    components*: seq[NodesComponents]
    taskpool*: Taskpool

  NodeConfig* = object
    useRepoStore*: bool = false
    findFreePorts*: bool = false
    basePort*: int = 8080
    createFullNode*: bool = false
    enableBootstrap*: bool = false
    enableDiscovery*: bool = true

converter toTuple*(
    nc: NodesComponents
): tuple[
  switch: Switch,
  blockDiscovery: Discovery,
  network: BlockExcNetwork,
  localStore: BlockStore,
  peerStore: PeerCtxStore,
  pendingBlocks: PendingBlocksManager,
  discovery: DiscoveryEngine,
  engine: BlockExcEngine,
  networkStore: NetworkStore,
] =
  (
    nc.switch, nc.blockDiscovery, nc.network, nc.localStore, nc.peerStore,
    nc.pendingBlocks, nc.discovery, nc.engine, nc.networkStore,
  )

converter toComponents*(cluster: NodesCluster): seq[NodesComponents] =
  cluster.components

proc nodes*(cluster: NodesCluster): seq[CodexNodeRef] =
  cluster.components.filterIt(it.node != nil).mapIt(it.node)

proc localStores*(cluster: NodesCluster): seq[BlockStore] =
  cluster.components.mapIt(it.localStore)

proc switches*(cluster: NodesCluster): seq[Switch] =
  cluster.components.mapIt(it.switch)

proc assignBlocks*(
    node: NodesComponents,
    dataset: TestDataset,
    indices: seq[int],
    putMerkleProofs = true,
): Future[void] {.async: (raises: [CatchableError]).} =
  let rootCid = dataset.tree.rootCid.tryGet()

  for i in indices:
    assert (await node.networkStore.putBlock(dataset.blocks[i])).isOk
    if putMerkleProofs:
      assert (
        await node.networkStore.putCidAndProof(
          rootCid, i, dataset.blocks[i].cid, dataset.tree.getProof(i).tryGet()
        )
      ).isOk

proc assignBlocks*(
    node: NodesComponents,
    dataset: TestDataset,
    indices: HSlice[int, int],
    putMerkleProofs = true,
): Future[void] {.async: (raises: [CatchableError]).} =
  await assignBlocks(node, dataset, indices.toSeq, putMerkleProofs)

proc assignBlocks*(
    node: NodesComponents, dataset: TestDataset, putMerkleProofs = true
): Future[void] {.async: (raises: [CatchableError]).} =
  await assignBlocks(node, dataset, 0 ..< dataset.blocks.len, putMerkleProofs)

proc generateNodes*(
    num: Natural, blocks: openArray[bt.Block] = [], config: NodeConfig = NodeConfig()
): NodesCluster =
  var
    components: seq[NodesComponents] = @[]
    taskpool = Taskpool.new()
    bootstrapNodes: seq[SignedPeerRecord] = @[]

  for i in 0 ..< num:
    let basePortForNode = config.basePort + 2 * i.int
    let listenPort =
      if config.findFreePorts:
        waitFor nextFreePort(basePortForNode)
      else:
        basePortForNode

    let bindPort =
      if config.findFreePorts:
        waitFor nextFreePort(listenPort + 1)
      else:
        listenPort + 1

    let
      listenAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/" & $listenPort).expect(
          "invalid multiaddress"
        )

      switch = newStandardSwitch(
        transportFlags = {ServerFlags.ReuseAddr},
        sendSignedPeerRecord = config.enableBootstrap,
        addrs =
          if config.findFreePorts:
            listenAddr
          else:
            MultiAddress.init("/ip4/127.0.0.1/tcp/0").expect("invalid multiaddress"),
      )

      network = BlockExcNetwork.new(switch)
      peerStore = PeerCtxStore.new()
      pendingBlocks = PendingBlocksManager.new()

    let (localStore, tempDbs, blockDiscovery) =
      if config.useRepoStore:
        let
          bdStore = TempLevelDb.new()
          repoStore = TempLevelDb.new()
          mdStore = TempLevelDb.new()
          store =
            RepoStore.new(repoStore.newDb(), mdStore.newDb(), clock = SystemClock.new())
          blockDiscoveryStore = bdStore.newDb()
          discovery =
            if config.enableDiscovery:
              Discovery.new(
                switch.peerInfo.privateKey,
                announceAddrs = @[listenAddr],
                bindPort = bindPort.Port,
                store = blockDiscoveryStore,
                bootstrapNodes = bootstrapNodes,
              )
            else:
              nullDiscovery()

        waitFor store.start()
        (store.BlockStore, @[bdStore, repoStore, mdStore], discovery)
      else:
        let
          store = CacheStore.new(blocks.mapIt(it))
          discovery =
            Discovery.new(switch.peerInfo.privateKey, announceAddrs = @[listenAddr])
        (store.BlockStore, newSeq[TempLevelDb](), discovery)

    let
      discovery = DiscoveryEngine.new(
        localStore, peerStore, network, blockDiscovery, pendingBlocks
      )
      advertiser = Advertiser.new(localStore, blockDiscovery)
      engine = BlockExcEngine.new(
        localStore, network, discovery, advertiser, peerStore, pendingBlocks
      )
      networkStore = NetworkStore.new(engine, localStore)

    switch.mount(network)

    let node =
      if config.createFullNode:
        let fullNode = CodexNodeRef.new(
          switch = switch,
          networkStore = networkStore,
          engine = engine,
          discovery = blockDiscovery,
          taskpool = taskpool,
        )

        if config.enableBootstrap:
          waitFor switch.peerInfo.update()
          let (announceAddrs, discoveryAddrs) = nattedAddress(
            NatConfig(hasExtIp: false, nat: NatNone),
            switch.peerInfo.addrs,
            bindPort.Port,
          )
          blockDiscovery.updateAnnounceRecord(announceAddrs)
          blockDiscovery.updateDhtRecord(discoveryAddrs)
          if blockDiscovery.dhtRecord.isSome:
            bootstrapNodes.add !blockDiscovery.dhtRecord

        fullNode
      else:
        nil

    let nodeComponent = NodesComponents(
      switch: switch,
      blockDiscovery: blockDiscovery,
      network: network,
      localStore: localStore,
      peerStore: peerStore,
      pendingBlocks: pendingBlocks,
      discovery: discovery,
      engine: engine,
      networkStore: networkStore,
      node: node,
      tempDbs: tempDbs,
    )

    components.add(nodeComponent)

  if config.createFullNode:
    for component in components:
      if component.node != nil:
        waitFor component.node.switch.start()
        waitFor component.node.start()

  return NodesCluster(components: components, taskpool: taskpool)

proc start*(nodes: NodesComponents) {.async: (raises: [CatchableError]).} =
  await allFuturesThrowing(
    nodes.switch.start(),
    #nodes.blockDiscovery.start(),
    nodes.engine.start(),
  )

proc stop*(nodes: NodesComponents) {.async: (raises: [CatchableError]).} =
  await allFuturesThrowing(
    nodes.switch.stop(),
    #   nodes.blockDiscovery.stop(),
    nodes.engine.stop(),
  )

proc start*(nodes: seq[NodesComponents]) {.async: (raises: [CatchableError]).} =
  await allFuturesThrowing(nodes.mapIt(it.start()).toSeq)

proc stop*(nodes: seq[NodesComponents]) {.async: (raises: [CatchableError]).} =
  await allFuturesThrowing(nodes.mapIt(it.stop()).toSeq)

proc connectNodes*(nodes: seq[Switch]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.connect(node.peerInfo.peerId, node.peerInfo.addrs)

proc connectNodes*(nodes: seq[NodesComponents]) {.async.} =
  await connectNodes(nodes.mapIt(it.switch))

proc connectNodes*(nodes: varargs[NodesComponents]): Future[void] =
  # varargs can't be captured on closures, and async procs are closures,
  # so we have to do this mess
  let copy = nodes.toSeq
  (
    proc() {.async.} =
      await connectNodes(copy.mapIt(it.switch))
  )()

proc connectNodes*(cluster: NodesCluster) {.async.} =
  await connectNodes(cluster.components)

proc cleanup*(cluster: NodesCluster) {.async.} =
  for component in cluster.components:
    if component.node != nil:
      await component.node.switch.stop()
      await component.node.stop()

  for component in cluster.components:
    for db in component.tempDbs:
      await db.destroyDb()

  for component in cluster.components:
    if component.tempDbs.len > 0:
      await RepoStore(component.localStore).stop()

  cluster.taskpool.shutdown()

proc linearTopology*(nodes: seq[NodesComponents]) {.async.} =
  for i in 0 .. nodes.len - 2:
    await connectNodes(nodes[i], nodes[i + 1])

proc downloadDataset*(
    node: NodesComponents, dataset: TestDataset
): Future[void] {.async.} =
  # This is the same as fetchBatched, but we don't construct CodexNodes so I can't use
  # it here.
  let requestAddresses = collect:
    for i in 0 ..< dataset.manifest.blocksCount:
      BlockAddress.init(dataset.manifest.treeCid, i)

  let blockCids = dataset.blocks.mapIt(it.cid).toHashSet()

  var count = 0
  for blockFut in (await node.networkStore.getBlocks(requestAddresses)):
    let blk = (await blockFut).tryGet()
    assert blk.cid in blockCids, "Unknown block CID: " & $blk.cid
    count += 1

  assert count == dataset.blocks.len, "Incorrect number of blocks downloaded"
