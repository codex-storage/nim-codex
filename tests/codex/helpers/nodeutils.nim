import std/sequtils

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
import pkg/codex/slots

import pkg/codex/node

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
    wallet*: WalletRef
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

converter toTuple*(
    nc: NodesComponents
): tuple[
  switch: Switch,
  blockDiscovery: Discovery,
  wallet: WalletRef,
  network: BlockExcNetwork,
  localStore: BlockStore,
  peerStore: PeerCtxStore,
  pendingBlocks: PendingBlocksManager,
  discovery: DiscoveryEngine,
  engine: BlockExcEngine,
  networkStore: NetworkStore,
] =
  (
    nc.switch, nc.blockDiscovery, nc.wallet, nc.network, nc.localStore, nc.peerStore,
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

      wallet =
        if config.createFullNode:
          WalletRef.new(EthPrivateKey.random())
        else:
          WalletRef.example
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
          discovery = Discovery.new(
            switch.peerInfo.privateKey,
            announceAddrs = @[listenAddr],
            bindPort = bindPort.Port,
            store = blockDiscoveryStore,
            bootstrapNodes = bootstrapNodes,
          )
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
        localStore, wallet, network, discovery, advertiser, peerStore, pendingBlocks
      )
      networkStore = NetworkStore.new(engine, localStore)

    switch.mount(network)

    let node =
      if config.createFullNode:
        let fullNode = CodexNodeRef.new(
          switch = switch,
          networkStore = networkStore,
          engine = engine,
          prover = Prover.none,
          discovery = blockDiscovery,
          taskpool = taskpool,
        )

        if config.enableBootstrap:
          waitFor switch.peerInfo.update()
          let natManager = newNatManager()
          defer:
            shutdownNat(natManager)
          let (announceAddrs, discoveryAddrs) = nattedAddress(
            natManager,
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
      wallet: wallet,
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

proc connectNodes*(nodes: seq[Switch]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.connect(node.peerInfo.peerId, node.peerInfo.addrs)

proc connectNodes*(nodes: seq[NodesComponents]) {.async.} =
  await connectNodes(nodes.mapIt(it.switch))

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
