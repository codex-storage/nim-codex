import std/os
import std/options

import pkg/asynctest
import pkg/chronos
import pkg/chronicles
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

  setup:
    file = open(path.splitFile().dir /../ "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file, chunkSize = BlockSize)
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)
    localStore = CacheStore.new()
    blockDiscovery = Discovery.new(switch.peerInfo, Port(0))
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
    var
      manifest = Manifest.new().tryGet()

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = bt.Block.new(chunk).tryGet()
      (await localStore.putBlock(blk)).tryGet()
      manifest.add(blk.cid)

    let
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
    var
      manifest = Manifest.new().tryGet()

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = bt.Block.new(chunk).tryGet()
      (await localStore.putBlock(blk)).tryGet()
      manifest.add(blk.cid)

    let
      manifestBlock = bt.Block.new(
          manifest.encode().tryGet(),
          codec = DagPBCodec
        ).tryGet()

    (await node.fetchBatched(
      manifest,
      batchSize = 3,
      proc(blocks: seq[bt.Block]) {.gcsafe, async.} =
        check blocks.len > 0 and blocks.len <= 3
    )).tryGet()

    (await node.fetchBatched(
      manifest,
      batchSize = 6,
      proc(blocks: seq[bt.Block]) {.gcsafe, async.} =
        check blocks.len > 0 and blocks.len <= 6
    )).tryGet()

    (await node.fetchBatched(
      manifest,
      batchSize = 9,
      proc(blocks: seq[bt.Block]) {.gcsafe, async.} =
        check blocks.len > 0 and blocks.len <= 9
    )).tryGet()

    (await node.fetchBatched(
      manifest,
      batchSize = 11,
      proc(blocks: seq[bt.Block]) {.gcsafe, async.} =
        check blocks.len > 0 and blocks.len <= 11
    )).tryGet()

  test "Store Data Stream":
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)

    var
      manifest = Manifest.new().tryGet()

    try:
      while (
        let chunk = await chunker.getBytes();
        chunk.len > 0):
        await stream.pushData(chunk)
        manifest.add(bt.Block.new(chunk).tryGet().cid)
    finally:
      await stream.pushEof()
      await stream.close()

    let
      manifestCid = (await storeFut).tryGet()

    check:
      (await localStore.hasBlock(manifestCid)).tryGet()

    var
      manifestBlock = (await localStore.getBlock(manifestCid)).tryGet().get()
      localManifest = Manifest.decode(manifestBlock).tryGet()

    check:
      manifest.len == localManifest.len
      manifest.cid == localManifest.cid

  test "Retrieve Data Stream":
    var
      manifest = Manifest.new().tryGet()
      original: seq[byte]

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = bt.Block.new(chunk).tryGet()
      original &= chunk
      (await localStore.putBlock(blk)).tryGet()
      manifest.add(blk.cid)

    let
      manifestBlock = bt.Block.new(
          manifest.encode().tryGet(),
          codec = DagPBCodec
        ).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let stream = (await node.retrieve(manifestBlock.cid)).tryGet()
    var data: seq[byte]
    while not stream.atEof:
      var
        buf = newSeq[byte](BlockSize)
        res = await stream.readOnce(addr buf[0], BlockSize div 2)
      buf.setLen(res)
      data &= buf

    check data == original

  test "Retrieve One Block":
    let
      testString = "Block 1"
      blk = bt.Block.new(testString.toBytes).tryGet()

    (await localStore.putBlock(blk)).tryGet()
    let stream = (await node.retrieve(blk.cid)).tryGet()

    var data = newSeq[byte](testString.len)
    await stream.readExactly(addr data[0], data.len)
    check string.fromBytes(data) == testString
