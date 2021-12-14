import std/os
import std/sequtils
import std/algorithm
import std/options

import pkg/asynctest
import pkg/chronos
import pkg/stew/byteutils

import pkg/nitro
import pkg/libp2p
import pkg/libp2p/errors

import pkg/dagger/rng
import pkg/dagger/stores
import pkg/dagger/blockexchange
import pkg/dagger/chunker
import pkg/dagger/node
import pkg/dagger/conf
import pkg/dagger/manifest
import pkg/dagger/blocktype as bt
import pkg/chronicles

import ./helpers
import ./examples

suite "Test Node":

  var
    switch: Switch
    wallet: WalletRef
    network: BlockExcNetwork
    localStore: MemoryStore
    engine: BlockExcEngine
    store: NetworkStore
    node: DaggerNodeRef

  setup:
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)
    localStore = MemoryStore.new()
    engine = BlockExcEngine.new(localStore, wallet, network)
    store = NetworkStore.new(engine, localStore)
    node = DaggerNodeRef.new(switch, store, engine)

    await node.start()

  teardown:
    await node.stop()

  test "Store Data Stream":
    let
      (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name
      file = open(path.splitFile().dir /../ "fixtures" / "test.jpg")
      chunker = FileChunker.new(file = file)
      stream = BufferStream.new()
      storeFut = node.store(stream)

    var
      manifest = BlocksManifest.init().tryGet()

    try:
      while (
        let chunk = await chunker.getBytes();
        chunk.len > 0):
        await stream.pushData(chunk)
        manifest.put(bt.Block.new(chunk).cid)
    finally:
      await stream.pushEof()
      await stream.close()

    let
      manifestCid = (await storeFut).tryGet()

    check:
      manifestCid in localStore

    var
      manifestBlock = (await localStore.getBlock(manifestCid)).get()
      localManifest = BlocksManifest.init(manifestBlock).tryGet()

    check:
      manifest.len == localManifest.len
      manifest.cid == localManifest.cid

  test "Retrieve Data Stream":
    let
      (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name
      file = open(path.splitFile().dir /../ "fixtures" / "test.jpg")
      chunker = FileChunker.new(file = file)

    var
      manifest = BlocksManifest.init().tryGet()
      original: seq[byte]

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let
        blk = bt.Block.new(chunk)

      original &= chunk
      await localStore.putBlock(blk)
      manifest.put(blk.cid)

    let
      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec)

    await localStore.putBlock(manifestBlock)

    let
      stream = (await node.retrieve(manifestBlock.cid)).tryGet()

    var data: seq[byte]
    while true:
      var
        buf = newSeq[byte](FileChunkSize)
        res = await stream.readOnce(addr buf[0], buf.len)

      if res <= 0:
        break

      buf.setLen(res)
      data &= buf

    check data == original
