import std/sequtils
import std/sugar
import std/algorithm
import std/tables

import pkg/asynctest
import pkg/chronos
import pkg/stew/byteutils

import pkg/libp2p
import pkg/libp2p/errors

import pkg/dagger/rng
import pkg/dagger/stores
import pkg/dagger/blockexchange
import pkg/dagger/chunker
import pkg/dagger/blocktype as bt

import ./mockdiscovery

import ../../helpers
import ../../examples

suite "Block Advertising and Discovery":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    switch: seq[Switch]
    blockexc: seq[NetworkStore]
    blocks: seq[bt.Block]

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

  teardown:
    switch = @[]
    blockexc = @[]

  test "Should discover want list":
    let
      s = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
      discovery = MockDiscovery.new(s.peerInfo, 0.Port)
      wallet = WalletRef.example
      network = BlockExcNetwork.new(s)
      localStore = CacheStore.new(blocks.mapIt( it ))
      engine = BlockExcEngine.new(localStore, wallet, network, discovery)

    s.mount(network)
    switch.add(s)

    await allFuturesThrowing(
      switch.mapIt( it.start() )
    )

    let
      pendingBlocks = blocks.mapIt(
        engine.pendingBlocks.getWantHandle(it.cid)
      )

    await engine.start() # fire up discovery loop
    discovery.findBlockProvidersHandler =
      proc(d: MockDiscovery, cid: Cid): seq[SignedPeerRecord] =
        engine.resolveBlocks(blocks.filterIt( it.cid == cid ))

  test "Should advertise have blocks":
    let
      s = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
      discovery = MockDiscovery.new(s.peerInfo, 0.Port)
      wallet = WalletRef.example
      network = BlockExcNetwork.new(s)
      localStore = CacheStore.new(blocks.mapIt( it ))
      engine = BlockExcEngine.new(localStore, wallet, network, discovery)

    s.mount(network)
    switch.add(s)

    await allFuturesThrowing(
      switch.mapIt( it.start() )
    )

    let
      advertised = initTable.collect:
        for b in blocks: {b.cid: newFuture[void]()}

    discovery.publishProvideHandler = proc(d: MockDiscovery, cid: Cid) =
      if cid in advertised and not advertised[cid].finished():
        advertised[cid].complete()

    await engine.start() # fire up advertise loop
    await allFuturesThrowing(
      allFinished(toSeq(advertised.values)))

suite "E2E - Multiple Nodes Discovery":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    switch: seq[Switch]
    blockexc: seq[NetworkStore]
    blocks: seq[bt.Block]

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    for _ in 0..<4:
      let
        s = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
        discovery = MockDiscovery.new(s.peerInfo, 0.Port)
        wallet = WalletRef.example
        network = BlockExcNetwork.new(s)
        localStore = CacheStore.new(blocks.mapIt( it ))
        engine = BlockExcEngine.new(localStore, wallet, network, discovery)
        networkStore = NetworkStore.new(engine, localStore)

      s.mount(network)
      switch.add(s)
      blockexc.add(networkStore)

  teardown:
    switch = @[]
    blockexc = @[]

  test "Should not launch discovery request if we are already connected":
    await allFuturesThrowing(
      blockexc.mapIt( it.engine.start() ) &
      switch.mapIt( it.start() )
    )

    await blockexc[0].engine.blocksHandler(switch[1].peerInfo.peerId, blocks)
    MockDiscovery(blockexc[0].engine.discovery)
      .findBlockProvidersHandler = proc(d: MockDiscovery, cid: Cid): seq[SignedPeerRecord] =
        check false

    await connectNodes(switch)
    let blk = await blockexc[1].engine.requestBlock(blocks[0].cid)

    await allFuturesThrowing(
      blockexc.mapIt( it.engine.stop() ) &
      switch.mapIt( it.stop() )
    )

  test "E2E - Should advertise and discover blocks":
    # Distribute the blocks amongst 1..3
    # Ask 0 to download everything without connecting him beforehand

    var advertised: Table[Cid, SignedPeerRecord]

    MockDiscovery(blockexc[1].engine.discovery)
      .publishProvideHandler = proc(d: MockDiscovery, cid: Cid) =
        advertised.add(cid, switch[1].peerInfo.signedPeerRecord)

    MockDiscovery(blockexc[2].engine.discovery)
      .publishProvideHandler = proc(d: MockDiscovery, cid: Cid) =
        advertised.add(cid, switch[2].peerInfo.signedPeerRecord)

    MockDiscovery(blockexc[3].engine.discovery)
      .publishProvideHandler = proc(d: MockDiscovery, cid: Cid) =
        advertised.add(cid, switch[3].peerInfo.signedPeerRecord)

    await blockexc[1].engine.blocksHandler(switch[0].peerInfo.peerId, blocks[0..5])
    await blockexc[2].engine.blocksHandler(switch[0].peerInfo.peerId, blocks[4..10])
    await blockexc[3].engine.blocksHandler(switch[0].peerInfo.peerId, blocks[10..15])

    MockDiscovery(blockexc[0].engine.discovery)
      .findBlockProvidersHandler = proc(d: MockDiscovery, cid: Cid): seq[SignedPeerRecord] =
        if cid in advertised:
          result.add(advertised[cid])

    let futs = collect(newSeq):
      for b in blocks:
        blockexc[0].engine.requestBlock(b.cid)

    await allFuturesThrowing(
      switch.mapIt( it.start() ) &
      blockexc.mapIt( it.engine.start() )
    )

    await allFutures(futs)

    await allFuturesThrowing(
      blockexc.mapIt( it.engine.stop() ) &
      switch.mapIt( it.stop() )
    )
