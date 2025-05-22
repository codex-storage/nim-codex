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
import pkg/codex/systemclock
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

proc fetchStreamData(stream: LPStream, datasetSize: int): Future[seq[byte]] {.async.} =
  var buf = newSeqUninitialized[byte](datasetSize)
  while not stream.atEof:
    var length = await stream.readOnce(addr buf[0], buf.len)
    if length <= 0:
      break
  assert buf.len == datasetSize
  buf

proc flatten[T](s: seq[seq[T]]): seq[T] =
  var t = newSeq[T](0)
  for ss in s:
    t &= ss
  return t

asyncchecksuite "Test Node - Slot Repair":
  var
    manifest: Manifest
    builder: Poseidon2Builder
    verifiable: Manifest
    verifiableBlock: bt.Block
    protected: Manifest

    tempLevelDbs: seq[TempLevelDb] = newSeq[TempLevelDb]()
    localStores: seq[RepoStore] = newSeq[RepoStore]()
    nodes: seq[CodexNodeRef] = newSeq[CodexNodeRef]()
    taskpool: Taskpool

  let numNodes = 12

  setup:
    taskpool = Taskpool.new()
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
        bdStore = TempLevelDb.new()
        blockDiscoveryStore = bdStore.newDb()
        repoStore = TempLevelDb.new()
        mdStore = TempLevelDb.new()
        localStore =
          RepoStore.new(repoStore.newDb(), mdStore.newDb(), clock = SystemClock.new())
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
          taskpool = taskpool,
        )

      await localStore.start()
      await switch.peerInfo.update()
      switch.mount(network)

      let (announceAddrs, discoveryAddrs) = nattedAddress(
        NatConfig(hasExtIp: false, nat: NatNone), switch.peerInfo.addrs, bindPort.Port
      )
      node.discovery.updateAnnounceRecord(announceAddrs)
      node.discovery.updateDhtRecord(discoveryAddrs)

      check node.discovery.dhtRecord.isSome
      bootstrapNodes.add !node.discovery.dhtRecord

      tempLevelDbs.add bdStore
      tempLevelDbs.add repoStore
      tempLevelDbs.add mdStore
      localStores.add localStore
      nodes.add node

    for node in nodes:
      await node.switch.start()
      await node.start()

  teardown:
    for node in nodes:
      await node.switch.stop()
      await node.stop()
    for s in tempLevelDbs:
      await s.destroyDb()
    for l in localStores:
      await l.stop()
    taskpool.shutdown()
    localStores = @[]
    nodes = @[]
    tempLevelDbs = @[]

  test "repair slots (2,1)":
    let
      numBlocks = 5
      datasetSize = numBlocks * DefaultBlockSize.int
      ecK = 2
      ecM = 1
      localStore = localStores[0]
      store = nodes[0].blockStore
      blocks =
        await makeRandomBlocks(datasetSize = datasetSize, blockSize = DefaultBlockSize)
      data = (
        block:
          collect(newSeq):
            for blk in blocks:
              blk.data
      ).flatten()
    assert blocks.len == numBlocks

    # Populate manifest in local store
    manifest = await storeDataGetManifest(localStore, blocks)
    let
      manifestBlock =
        bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
      erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider, taskpool)

    (await localStore.putBlock(manifestBlock)).tryGet()

    protected = (await erasure.encode(manifest, ecK, ecM)).tryGet()
    builder = Poseidon2Builder.new(localStore, protected).tryGet()
    verifiable = (await builder.buildManifest()).tryGet()
    verifiableBlock =
      bt.Block.new(verifiable.encode().tryGet(), codec = ManifestCodec).tryGet()

    # Populate protected manifest in local store
    (await localStore.putBlock(verifiableBlock)).tryGet()

    var request = StorageRequest.example
    request.content.cid = verifiableBlock.cid
    request.ask.slots = protected.numSlots.uint64
    request.ask.slotSize = DefaultBlockSize.uint64

    for i in 0 ..< protected.numSlots.uint64:
      (await nodes[i + 1].onStore(request, i, nil, isRepairing = false)).tryGet()

    await nodes[0].switch.stop() # acts as client
    await nodes[1].switch.stop() # slot 0 missing now

    # repair missing slot
    (await nodes[4].onStore(request, 0.uint64, nil, isRepairing = true)).tryGet()

    await nodes[2].switch.stop() # slot 1 missing now

    (await nodes[5].onStore(request, 1.uint64, nil, isRepairing = true)).tryGet()

    await nodes[3].switch.stop() # slot 2 missing now

    (await nodes[6].onStore(request, 2.uint64, nil, isRepairing = true)).tryGet()

    await nodes[4].switch.stop() # slot 0 missing now

    # repair missing slot from repaired slots
    (await nodes[7].onStore(request, 0.uint64, nil, isRepairing = true)).tryGet()

    await nodes[5].switch.stop() # slot 1 missing now

    # repair missing slot from repaired slots
    (await nodes[8].onStore(request, 1.uint64, nil, isRepairing = true)).tryGet()

    await nodes[6].switch.stop() # slot 2 missing now

    # repair missing slot from repaired slots
    (await nodes[9].onStore(request, 2.uint64, nil, isRepairing = true)).tryGet()

    let
      stream = (await nodes[10].retrieve(verifiableBlock.cid, local = false)).tryGet()
      expectedData = await fetchStreamData(stream, datasetSize)
    assert expectedData.len == data.len
    assert expectedData == data

  test "repair slots (3,2)":
    let
      numBlocks = 40
      datasetSize = numBlocks * DefaultBlockSize.int
      ecK = 3
      ecM = 2
      localStore = localStores[0]
      store = nodes[0].blockStore
      blocks =
        await makeRandomBlocks(datasetSize = datasetSize, blockSize = DefaultBlockSize)
      data = (
        block:
          collect(newSeq):
            for blk in blocks:
              blk.data
      ).flatten()
    assert blocks.len == numBlocks

    # Populate manifest in local store
    manifest = await storeDataGetManifest(localStore, blocks)
    let
      manifestBlock =
        bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
      erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider, taskpool)

    (await localStore.putBlock(manifestBlock)).tryGet()

    protected = (await erasure.encode(manifest, ecK, ecM)).tryGet()
    builder = Poseidon2Builder.new(localStore, protected).tryGet()
    verifiable = (await builder.buildManifest()).tryGet()
    verifiableBlock =
      bt.Block.new(verifiable.encode().tryGet(), codec = ManifestCodec).tryGet()

    # Populate protected manifest in local store
    (await localStore.putBlock(verifiableBlock)).tryGet()

    var request = StorageRequest.example
    request.content.cid = verifiableBlock.cid
    request.ask.slots = protected.numSlots.uint64
    request.ask.slotSize = DefaultBlockSize.uint64

    for i in 0 ..< protected.numSlots.uint64:
      (await nodes[i + 1].onStore(request, i, nil, isRepairing = false)).tryGet()

    await nodes[0].switch.stop() # acts as client
    await nodes[1].switch.stop() # slot 0 missing now
    await nodes[3].switch.stop() # slot 2 missing now

    # repair missing slots
    (await nodes[6].onStore(request, 0.uint64, nil, isRepairing = true)).tryGet()
    (await nodes[7].onStore(request, 2.uint64, nil, isRepairing = true)).tryGet()

    await nodes[2].switch.stop() # slot 1 missing now
    await nodes[4].switch.stop() # slot 3 missing now

    # repair missing slots from repaired slots
    (await nodes[8].onStore(request, 1.uint64, nil, isRepairing = true)).tryGet()
    (await nodes[9].onStore(request, 3.uint64, nil, isRepairing = true)).tryGet()

    await nodes[5].switch.stop() # slot 4 missing now

    # repair missing slot from repaired slots
    (await nodes[10].onStore(request, 4.uint64, nil, isRepairing = true)).tryGet()

    let
      stream = (await nodes[11].retrieve(verifiableBlock.cid, local = false)).tryGet()
      expectedData = await fetchStreamData(stream, datasetSize)
    assert expectedData.len == data.len
    assert expectedData == data
