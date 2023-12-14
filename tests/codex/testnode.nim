import std/os
import std/options
import std/math
import std/times

import pkg/asynctest
import pkg/chronos
import pkg/chronicles
import pkg/stew/byteutils
import pkg/datastore
import pkg/questionable
import pkg/questionable/results
import pkg/stint

import pkg/nitro
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/stores
import pkg/codex/clock
import pkg/codex/contracts
import pkg/codex/systemclock
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/node
import pkg/codex/manifest
import pkg/codex/discovery
import pkg/codex/blocktype as bt

import ../examples
import ./helpers
import ./helpers/mockmarket
import ./helpers/mockclock

proc toTimesDuration(d: chronos.Duration): times.Duration =
  initDuration(seconds=d.seconds)

asyncchecksuite "Test Node":
  let
    (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name

  var
    file: File
    chunker: Chunker
    switch: Switch
    wallet: WalletRef
    network: BlockExcNetwork
    clock: Clock
    localStore: RepoStore
    localStoreRepoDs: DataStore
    localStoreMetaDs: DataStore
    engine: BlockExcEngine
    store: NetworkStore
    node: CodexNodeRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    discovery: DiscoveryEngine

  proc fetch(T: type Manifest, chunker: Chunker): Future[Manifest] {.async.} =
    # Collect blocks from Chunker into Manifest
    await storeDataGetManifest(localStore, chunker)

  proc retrieve(cid: Cid): Future[seq[byte]] {.async.} =
    # Retrieve an entire file contents by file Cid
    let
      oddChunkSize = math.trunc(DefaultBlockSize.float/1.359).int  # Let's check that node.retrieve can correctly rechunk data
      stream = (await node.retrieve(cid)).tryGet()
    var
      data: seq[byte]

    defer: await stream.close()

    while not stream.atEof:
      var
        buf = newSeq[byte](oddChunkSize)
        res = await stream.readOnce(addr buf[0], oddChunkSize)
      check res <= oddChunkSize
      buf.setLen(res)
      data &= buf

    return data

  setup:
    file = open(path.splitFile().dir /../ "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file, chunkSize = DefaultBlockSize)
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)

    clock = SystemClock.new()
    localStoreMetaDs = SQLiteDatastore.new(Memory).tryGet()
    localStoreRepoDs = SQLiteDatastore.new(Memory).tryGet()
    localStore = RepoStore.new(localStoreRepoDs, localStoreMetaDs, clock=clock)
    await localStore.start()

    blockDiscovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0")
        .expect("Should return multiaddress")])
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    discovery = DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)
    engine = BlockExcEngine.new(localStore, wallet, network, discovery, peerStore, pendingBlocks)
    store = NetworkStore.new(engine, localStore)
    node = CodexNodeRef.new(switch, store, engine, nil, blockDiscovery) # TODO: pass `Erasure`

    await node.start()

  teardown:
    close(file)
    await node.stop()

  test "Fetch Manifest":
    let
      manifest = await Manifest.fetch(chunker)

      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let
      fetched = (await node.fetchManifest(manifestBlock.cid)).tryGet()

    check:
      fetched == manifest

  test "Block Batching":
    let manifest = await Manifest.fetch(chunker)

    for batchSize in 1..12:
      (await node.fetchBatched(
        manifest,
        batchSize = batchSize,
        proc(blocks: seq[bt.Block]): Future[?!void] {.gcsafe, async.} =
          check blocks.len > 0 and blocks.len <= batchSize
          return success()
      )).tryGet()

  test "Store and retrieve Data Stream":
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)
      oddChunkSize = math.trunc(DefaultBlockSize.float/3.14).NBytes  # Let's check that node.store can correctly rechunk these odd chunks
      oddChunker = FileChunker.new(file = file, chunkSize = oddChunkSize, pad = false)  # TODO: doesn't work with pad=tue
    var
      original: seq[byte]

    try:
      while (
        let chunk = await oddChunker.getBytes();
        chunk.len > 0):
        original &= chunk
        await stream.pushData(chunk)
    finally:
      await stream.pushEof()
      await stream.close()

    let
      manifestCid = (await storeFut).tryGet()
    check:
      (await localStore.hasBlock(manifestCid)).tryGet()

    let
      manifestBlock = (await localStore.getBlock(manifestCid)).tryGet()
      localManifest = Manifest.decode(manifestBlock).tryGet()

    let data = await retrieve(manifestCid)

    check:
      data.len == localManifest.datasetSize.int
      data.len == original.len
      sha256.digest(data) == sha256.digest(original)

  test "Retrieve One Block":
    let
      testString = "Block 1"
      blk = bt.Block.new(testString.toBytes).tryGet()

    (await localStore.putBlock(blk)).tryGet()
    let stream = (await node.retrieve(blk.cid)).tryGet()
    defer: await stream.close()

    var data = newSeq[byte](testString.len)
    await stream.readExactly(addr data[0], data.len)
    check string.fromBytes(data) == testString


asyncchecksuite "Test Node - host contracts":
  let
    (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name

  var
    file: File
    chunker: Chunker
    switch: Switch
    wallet: WalletRef
    network: BlockExcNetwork
    clock: MockClock
    localStore: RepoStore
    localStoreRepoDs: DataStore
    localStoreMetaDs: DataStore
    engine: BlockExcEngine
    store: NetworkStore
    sales: Sales
    node: CodexNodeRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    discovery: DiscoveryEngine
    manifest: Manifest
    manifestCid: string

  proc fetch(T: type Manifest, chunker: Chunker): Future[Manifest] {.async.} =
    # Collect blocks from Chunker into Manifest
    await storeDataGetManifest(localStore, chunker)

  setup:
    file = open(path.splitFile().dir /../ "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file, chunkSize = DefaultBlockSize)
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)

    clock = MockClock.new()
    localStoreMetaDs = SQLiteDatastore.new(Memory).tryGet()
    localStoreRepoDs = SQLiteDatastore.new(Memory).tryGet()
    localStore = RepoStore.new(localStoreRepoDs, localStoreMetaDs, clock=clock)
    await localStore.start()

    blockDiscovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0")
        .expect("Should return multiaddress")])
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    discovery = DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)
    engine = BlockExcEngine.new(localStore, wallet, network, discovery, peerStore, pendingBlocks)
    store = NetworkStore.new(engine, localStore)
    node = CodexNodeRef.new(switch, store, engine, nil, blockDiscovery) # TODO: pass `Erasure`

    # Setup Host Contracts and dependencies
    let market = MockMarket.new()
    sales = Sales.new(market, clock, localStore)
    let hostContracts = some HostInteractions.new(clock, sales)
    node.contracts = (ClientInteractions.none, hostContracts, ValidatorInteractions.none)

    await node.start()

    # Populate manifest in local store
    manifest = await storeDataGetManifest(localStore, chunker)
    let manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec
      ).tryGet()
    manifestCid = $(manifestBlock.cid)
    (await localStore.putBlock(manifestBlock)).tryGet()

  teardown:
    close(file)
    await node.stop()

  test "onExpiryUpdate callback is set":
    check sales.onExpiryUpdate.isSome

  test "onExpiryUpdate callback":
    let
      # The blocks have set default TTL, so in order to update it we have to have larger TTL
      expectedExpiry: SecondsSince1970 = clock.now + DefaultBlockTtl.seconds + 11123
      expiryUpdateCallback = !sales.onExpiryUpdate

    (await expiryUpdateCallback(manifestCid, expectedExpiry)).tryGet()

    for index in 0..<manifest.blocksCount:
      let blk = (await localStore.getBlock(manifest.treeCid, index)).tryGet
      let expiryKey = (createBlockExpirationMetadataKey(blk.cid)).tryGet
      let expiry = await localStoreMetaDs.get(expiryKey)

      check (expiry.tryGet).toSecondsSince1970 == expectedExpiry

  test "onStore callback is set":
    check sales.onStore.isSome

  test "onStore callback":
    let onStore = !sales.onStore
    var request = StorageRequest.example
    request.content.cid = manifestCid
    request.expiry = (getTime() + DefaultBlockTtl.toTimesDuration + 1.hours).toUnix.u256
    var fetchedBytes: uint = 0

    let onBatch = proc(blocks: seq[bt.Block]): Future[?!void] {.async.} =
      for blk in blocks:
        fetchedBytes += blk.data.len.uint
      return success()

    (await onStore(request, 0.u256, onBatch)).tryGet()
    check fetchedBytes == 2291520

    for index in 0..<manifest.blocksCount:
      let blk = (await localStore.getBlock(manifest.treeCid, index)).tryGet
      let expiryKey = (createBlockExpirationMetadataKey(blk.cid)).tryGet
      let expiry = await localStoreMetaDs.get(expiryKey)

      check (expiry.tryGet).toSecondsSince1970 == request.expiry.toSecondsSince1970
