import std/options
import std/importutils

import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/taskpools

import pkg/nitro
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/logutils
import pkg/codex/stores
import pkg/codex/contracts
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/slots
import pkg/codex/manifest
import pkg/codex/discovery
import pkg/codex/erasure
import pkg/codex/blocktype as bt
import pkg/codex/indexingstrategy
import pkg/codex/nat
import pkg/codex/utils/natutils
import pkg/chronos/transports/stream

import pkg/codex/node {.all.}

import ../../asynctest
import ../../examples
import ../helpers

privateAccess(CodexNodeRef) # enable access to private fields

logScope:
  topics = "testSlotRepair"

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

asyncchecksuite "Test Node - Slot Repair":
  var
    manifest: Manifest
    builder: Poseidon2Builder
    verifiable: Manifest
    verifiableBlock: bt.Block
    protected: Manifest

    localStores: seq[CacheStore] = newSeq[CacheStore]()
    nodes: seq[CodexNodeRef] = newSeq[CodexNodeRef]()

  let
    numNodes = 11
    numBlocks = 24
    ecK = 3
    ecM = 2

  setup:
    var bootstrapNodes: seq[SignedPeerRecord] = @[]
    for i in 0 ..< numNodes:
      let
        listenPort = await nextFreePort(8080 + 2 * i)
        bindPort = await nextFreePort(listenPort + 1)
        listenAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/" & $listenPort).expect(
            "invalid multiaddress"
          )
        switch = newStandardSwitch(
          transportFlags = {ServerFlags.ReuseAddr},
          sendSignedPeerRecord = true,
          addrs = listenAddr,
        )
        wallet = WalletRef.new(EthPrivateKey.random())
        network = BlockExcNetwork.new(switch)
        peerStore = PeerCtxStore.new()
        pendingBlocks = PendingBlocksManager.new()
        blockDiscoveryStore = TempLevelDb.new().newDb()
        localStore = CacheStore.new()
        blockDiscovery = Discovery.new(
          switch.peerInfo.privateKey,
          announceAddrs = @[listenAddr],
          bindPort = bindPort.Port,
          store = blockDiscoveryStore,
          bootstrapNodes = bootstrapNodes,
        )
        discovery = DiscoveryEngine.new(
          localStore, peerStore, network, blockDiscovery, pendingBlocks
        )
        advertiser = Advertiser.new(localStore, blockDiscovery)
        engine = BlockExcEngine.new(
          localStore, wallet, network, discovery, advertiser, peerStore, pendingBlocks
        )
        store = NetworkStore.new(engine, localStore)
        node = CodexNodeRef.new(
          switch = switch,
          networkStore = store,
          engine = engine,
          prover = Prover.none,
          discovery = blockDiscovery,
          taskpool = Taskpool.new(),
        )

      await switch.peerInfo.update()
      switch.mount(network)

      let (announceAddrs, discoveryAddrs) = nattedAddress(
        NatConfig(hasExtIp: false, nat: NatNone), switch.peerInfo.addrs, bindPort.Port
      )
      node.discovery.updateAnnounceRecord(announceAddrs)
      node.discovery.updateDhtRecord(discoveryAddrs)

      check node.discovery.dhtRecord.isSome
      bootstrapNodes.add !node.discovery.dhtRecord

      localStores.add localStore
      nodes.add node

    for node in nodes:
      await node.switch.start()
      await node.start()

    let
      localStore = localStores[0]
      store = nodes[0].blockStore

    let blocks =
      await makeRandomBlocks(datasetSize = numBlocks * 64.KiBs.int, blockSize = 64.KiBs)
    assert blocks.len == numBlocks

    # Populate manifest in local store
    manifest = await storeDataGetManifest(localStore, blocks)
    let
      manifestBlock =
        bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
      erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider, Taskpool.new)

    (await localStore.putBlock(manifestBlock)).tryGet()

    protected = (await erasure.encode(manifest, ecK, ecM)).tryGet()
    builder = Poseidon2Builder.new(localStore, protected).tryGet()
    verifiable = (await builder.buildManifest()).tryGet()
    verifiableBlock =
      bt.Block.new(verifiable.encode().tryGet(), codec = ManifestCodec).tryGet()

    # Populate protected manifest in local store
    (await localStore.putBlock(verifiableBlock)).tryGet()

  teardown:
    for node in nodes:
      await node.switch.stop()
    localStores = @[]
    nodes = @[]

  test "repair slot":
    var request = StorageRequest.example
    request.content.cid = verifiableBlock.cid
    request.ask.slots = protected.numSlots.uint64
    request.ask.slotSize = DefaultBlockSize.uint64

    for i in 0 ..< protected.numSlots.uint64:
      (await nodes[i + 1].onStore(request, i, nil, isRepairing = false)).tryGet()

    await nodes[0].switch.stop() # acts as client
    await nodes[1].switch.stop() # slot 0 missing now
    await nodes[3].switch.stop() # slot 2 missing now

    # repair missing slot
    (await nodes[6].onStore(request, 0.uint64, nil, isRepairing = true)).tryGet()
    (await nodes[7].onStore(request, 2.uint64, nil, isRepairing = true)).tryGet()

    await nodes[2].switch.stop() # slot 1 missing now
    await nodes[4].switch.stop() # slot 3 missing now

    (await nodes[8].onStore(request, 1.uint64, nil, isRepairing = true)).tryGet()
    (await nodes[9].onStore(request, 3.uint64, nil, isRepairing = true)).tryGet()

    await nodes[5].switch.stop() # slot 4 missing now

    (await nodes[10].onStore(request, 4.uint64, nil, isRepairing = true)).tryGet()
