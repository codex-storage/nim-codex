import std/os
import std/options
import std/math
import std/times
import std/sequtils
import std/importutils

import pkg/asynctest
import pkg/chronos
import pkg/chronicles
import pkg/stew/byteutils
import pkg/datastore
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/poseidon2
import pkg/poseidon2/io

import pkg/nitro
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/stores
import pkg/codex/clock
import pkg/codex/contracts
import pkg/codex/systemclock
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/slots
import pkg/codex/manifest
import pkg/codex/discovery
import pkg/codex/erasure
import pkg/codex/merkletree
import pkg/codex/blocktype as bt

import pkg/codex/node {.all.}

import ../examples
import ./helpers
import ./helpers/mockmarket
import ./helpers/mockclock

privateAccess(CodexNodeRef) # enable access to private fields

proc toTimesDuration(d: chronos.Duration): times.Duration =
  initDuration(seconds = d.seconds)

proc drain(
  stream: LPStream | Result[lpstream.LPStream, ref CatchableError]):
  Future[seq[byte]] {.async.} =

  let
    stream =
      when typeof(stream) is Result[lpstream.LPStream, ref CatchableError]:
        stream.tryGet()
      else:
        stream

  defer:
    await stream.close()

  var data: seq[byte]
  while not stream.atEof:
    var
      buf = newSeq[byte](DefaultBlockSize.int)
      res = await stream.readOnce(addr buf[0], DefaultBlockSize.int)
    check res <= DefaultBlockSize.int
    buf.setLen(res)
    data &= buf

  data

proc pipeChunker(stream: BufferStream, chunker: Chunker) {.async.} =
  try:
    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):
      await stream.pushData(chunk)
  finally:
    await stream.pushEof()
    await stream.close()

template setupAndTearDown() {.dirty.} =
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
    erasure: Erasure

  let
    path = currentSourcePath().parentDir

  setup:
    file = open(path /../ "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file, chunkSize = DefaultBlockSize)
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)

    clock = SystemClock.new()
    localStoreMetaDs = SQLiteDatastore.new(Memory).tryGet()
    localStoreRepoDs = SQLiteDatastore.new(Memory).tryGet()
    localStore = RepoStore.new(localStoreRepoDs, localStoreMetaDs, clock = clock)
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
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
    node = CodexNodeRef.new(switch, store, engine, erasure, blockDiscovery)

    await node.start()

  teardown:
    close(file)
    await node.stop()

asyncchecksuite "Test Node - Basic":
  setupAndTearDown()

  test "Fetch Manifest":
    let
      manifest = await storeDataGetManifest(localStore, chunker)

      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let
      fetched = (await node.fetchManifest(manifestBlock.cid)).tryGet()

    check:
      fetched == manifest

  test "Block Batching":
    let manifest = await storeDataGetManifest(localStore, chunker)

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
      oddChunkSize = math.trunc(DefaultBlockSize.float / 3.14).NBytes  # Let's check that node.store can correctly rechunk these odd chunks
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
      manifestBlock = (await localStore.getBlock(manifestCid)).tryGet()
      localManifest = Manifest.decode(manifestBlock).tryGet()
      data = await (await node.retrieve(manifestCid)).drain()

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

  test "Setup purchase request":
    let
      manifest = await storeDataGetManifest(localStore, chunker)
      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec).tryGet()

      protected = (await erasure.encode(manifest, 3, 2)).tryGet()
      builder = SlotsBuilder.new(localStore, protected).tryGet()
      verifiable = (await builder.buildManifest()).tryGet()
      verifiableBlock = bt.Block.new(
        verifiable.encode().tryGet(),
        codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let
      request = (await node.setupRequest(
        cid = manifestBlock.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100.u256,
        reward = 2.u256,
        proofProbability = 3.u256,
        expiry = 200.u256,
        collateral = 200.u256)).tryGet

    check:
      (await verifiableBlock.cid in localStore) == true
      request.content.cid == $verifiableBlock.cid
      request.content.merkleRoot == builder.slotsRoot.get.toBytes

asyncchecksuite "Test Node - Host contracts":
  setupAndTearDown()

  var
    sales: Sales
    purchasing: Purchasing
    manifest: Manifest
    manifestCidStr: string
    manifestCid: Cid
    market: MockMarket

  setup:
    # Setup Host Contracts and dependencies
    market = MockMarket.new()
    sales = Sales.new(market, clock, localStore)

    node.contracts = (
      none ClientInteractions,
      some HostInteractions.new(clock, sales),
      none ValidatorInteractions)

    await node.start()

    # Populate manifest in local store
    manifest = await storeDataGetManifest(localStore, chunker)
    let
      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec).tryGet()

    manifestCid = manifestBlock.cid
    manifestCidStr = $(manifestCid)

    (await localStore.putBlock(manifestBlock)).tryGet()

  test "onExpiryUpdate callback is set":
    check sales.onExpiryUpdate.isSome

  test "onExpiryUpdate callback":
    let
      # The blocks have set default TTL, so in order to update it we have to have larger TTL
      expectedExpiry: SecondsSince1970 = clock.now + DefaultBlockTtl.seconds + 11123
      expiryUpdateCallback = !sales.onExpiryUpdate

    (await expiryUpdateCallback(manifestCidStr, expectedExpiry)).tryGet()

    for index in 0..<manifest.blocksCount:
      let
        blk = (await localStore.getBlock(manifest.treeCid, index)).tryGet
        expiryKey = (createBlockExpirationMetadataKey(blk.cid)).tryGet
        expiry = await localStoreMetaDs.get(expiryKey)

      check (expiry.tryGet).toSecondsSince1970 == expectedExpiry

  test "onStore callback is set":
    check sales.onStore.isSome

  test "onStore callback":
    let onStore = !sales.onStore
    var request = StorageRequest.example
    request.content.cid = manifestCidStr
    request.expiry = (getTime() + DefaultBlockTtl.toTimesDuration + 1.hours).toUnix.u256
    var fetchedBytes: uint = 0

    let onBatch = proc(blocks: seq[bt.Block]): Future[?!void] {.async.} =
      for blk in blocks:
        fetchedBytes += blk.data.len.uint
      return success()

    (await onStore(request, 0.u256, onBatch)).tryGet()
    check fetchedBytes == 2293760

    for index in 0..<manifest.blocksCount:
      let
        blk = (await localStore.getBlock(manifest.treeCid, index)).tryGet
        expiryKey = (createBlockExpirationMetadataKey(blk.cid)).tryGet
        expiry = await localStoreMetaDs.get(expiryKey)

      check (expiry.tryGet).toSecondsSince1970 == request.expiry.toSecondsSince1970
