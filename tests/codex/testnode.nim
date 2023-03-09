import std/os
import std/options
import std/math

import pkg/asynctest
import pkg/chronos
import pkg/stew/byteutils

import pkg/nitro
import pkg/libp2p
import pkg/libp2pdht/discv5/protocol as discv5

import pkg/codex/stores
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/node
import pkg/codex/manifest
import pkg/codex/discovery
import pkg/codex/blocktype as bt

import ./helpers

suite "Test Node":
  let
    (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name

  var
    file: File
    chunker: Chunker
    switch: Switch
    wallet: WalletRef
    network: BlockExcNetwork
    localStore: CacheStore
    engine: BlockExcEngine
    store: NetworkStore
    node: CodexNodeRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    discovery: DiscoveryEngine

  proc fetch(T: type Manifest, chunker: Chunker): Future[Manifest] {.async.} =
    # Collect blocks from Chunker into Manifest
    var
      manifest = Manifest.new().tryGet()

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = bt.Block.new(chunk).tryGet()
      (await localStore.putBlock(blk)).tryGet()
      manifest.add(blk.cid)

    return manifest

  proc retrieve(cid: Cid): Future[seq[byte]] {.async.} =
    # Retrieve an entire file contents by file Cid
    let
      oddChunkSize = math.trunc(BlockSize/1.359).int  # Let's check that node.retrieve can correctly rechunk data
      stream = (await node.retrieve(cid)).tryGet()
    var
      data: seq[byte]

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
    chunker = FileChunker.new(file = file, chunkSize = BlockSize)
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)
    localStore = CacheStore.new()
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
          codec = DagPBCodec
        ).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let
      fetched = (await node.fetchManifest(manifestBlock.cid)).tryGet()

    check:
      fetched.cid == manifest.cid
      fetched.blocks == manifest.blocks

  test "Block Batching":
    let
      manifest = await Manifest.fetch(chunker)

    for batchSize in 1..12:
      (await node.fetchBatched(
        manifest,
        batchSize = batchSize,
        proc(blocks: seq[bt.Block]) {.gcsafe, async.} =
          check blocks.len > 0 and blocks.len <= batchSize
      )).tryGet()

  test "Store and retrieve Data Stream":
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)
      oddChunkSize = math.trunc(BlockSize/3.14).int  # Let's check that node.store can correctly rechunk these odd chunks
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

    let
      data = await retrieve(manifestCid)
    check:
      data.len == localManifest.originalBytes
      data.len == original.len
      sha256.digest(data) == sha256.digest(original)

  test "Retrieve One Block":
    let
      testString = "Block 1"
      blk = bt.Block.new(testString.toBytes).tryGet()

    (await localStore.putBlock(blk)).tryGet()
    let stream = (await node.retrieve(blk.cid)).tryGet()

    var data = newSeq[byte](testString.len)
    await stream.readExactly(addr data[0], data.len)
    check string.fromBytes(data) == testString
