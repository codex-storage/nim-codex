import std/os
import std/sequtils
import std/algorithm

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

  test "Test store":
    let
      (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name
      file = open(path.splitFile().dir /../ "fixtures" / "test.jpg")
      chunker = FileChunker.new(file = file)

    let
      stream = BufferStream.new()
      storeFut = node.store(stream)

    without var manifest =? BlocksManifest.init():
      fail()

    try:
      while true:
        let
          chunk = await chunker.getBytes()

        if chunk.len <= 0:
          break

        manifest.put(bt.Block.new(chunk).cid)
        await stream.pushData(chunk)
    finally:
      await stream.pushEof()
      await stream.close()

    without manifestCid =? (await storeFut):
      fail()

    check manifestCid in localStore

    without manifestBlock =? await localStore.getBlock(manifestCid):
      fail()

    without var localManifest =? BlocksManifest.init(manifestBlock):
      fail()

    check manifest.treeHash() == localManifest.treeHash()
