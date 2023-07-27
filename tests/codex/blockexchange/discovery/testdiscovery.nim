import std/sequtils
import std/sugar
import std/tables

import pkg/asynctest
import pkg/chronos

import pkg/libp2p except setup
import pkg/libp2p/errors

import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/manifest
import pkg/codex/blocktype as bt

import ../../helpers/mockdiscovery

import ../../helpers
import ../../examples

asyncchecksuite "Block Advertising and Discovery":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    blocks: seq[bt.Block]
    manifest: Manifest
    manifestBlock: bt.Block
    switch: Switch
    peerStore: PeerCtxStore
    blockDiscovery: MockDiscovery
    discovery: DiscoveryEngine
    wallet: WalletRef
    network: BlockExcNetwork
    localStore: CacheStore
    engine: BlockExcEngine
    pendingBlocks: PendingBlocksManager

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
    blockDiscovery = MockDiscovery.new()
    wallet = WalletRef.example
    network = BlockExcNetwork.new(switch)
    localStore = CacheStore.new(blocks.mapIt( it ))
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    manifest = Manifest.new( blocks.mapIt( it.cid ) ).tryGet()
    manifestBlock = bt.Block.new(
      manifest.encode().tryGet(), codec = DagPBCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    discovery = DiscoveryEngine.new(
      localStore,
      peerStore,
      network,
      blockDiscovery,
      pendingBlocks,
      minPeersPerBlock = 1)

    engine = BlockExcEngine.new(
      localStore,
      wallet,
      network,
      discovery,
      peerStore,
      pendingBlocks)

    switch.mount(network)

  test "Should discover want list":
    let
      pendingBlocks = blocks.mapIt(
        engine.pendingBlocks.getWantHandle(it.cid)
      )

    await engine.start()

    blockDiscovery.publishBlockProvideHandler =
      proc(d: MockDiscovery, cid: Cid): Future[void] {.async, gcsafe.} =
        return

    blockDiscovery.findBlockProvidersHandler =
      proc(d: MockDiscovery, cid: Cid): Future[seq[SignedPeerRecord]] {.async.} =
        await engine.resolveBlocks(blocks.filterIt( it.cid == cid ))

    await allFuturesThrowing(
      allFinished(pendingBlocks))

    await engine.stop()

  test "Should advertise both manifests and blocks":
    let
      advertised = initTable.collect:
        for b in (blocks & manifestBlock): {b.cid: newFuture[void]()}

    blockDiscovery
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid) {.async.} =
        if cid in advertised and not advertised[cid].finished():
          advertised[cid].complete()

    discovery.advertiseType = BlockType.Both
    await engine.start() # fire up advertise loop
    await allFuturesThrowing(
      allFinished(toSeq(advertised.values)))
    await engine.stop()

  test "Should advertise local manifests":
    let
      advertised = newFuture[Cid]()

    blockDiscovery
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid) {.async.} =
        check manifestBlock.cid == cid
        advertised.complete(cid)

    discovery.advertiseType = BlockType.Manifest
    await engine.start() # fire up advertise loop
    check (await advertised.wait(10.millis)) == manifestBlock.cid
    await engine.stop()

  test "Should advertise local blocks":
    let
      advertised = initTable.collect:
        for b in blocks: {b.cid: newFuture[void]()}

    blockDiscovery
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid) {.async.} =
        if cid in advertised and not advertised[cid].finished():
          advertised[cid].complete()

    discovery.advertiseType = BlockType.Block
    await engine.start() # fire up advertise loop
    await allFuturesThrowing(
      allFinished(toSeq(advertised.values)))
    await engine.stop()

  test "Should not launch discovery if remote peer has block":
    let
      pendingBlocks = blocks.mapIt(
        engine.pendingBlocks.getWantHandle(it.cid)
      )
      peerId = PeerId.example
      haves = collect(initTable()):
        for blk in blocks:
          { blk.cid: Presence(cid: blk.cid, price: 0.u256) }

    engine.peers.add(
      BlockExcPeerCtx(
        id: peerId,
        blocks: haves
    ))

    blockDiscovery.findBlockProvidersHandler =
      proc(d: MockDiscovery, cid: Cid): Future[seq[SignedPeerRecord]] =
        check false

    await engine.start() # fire up discovery loop
    engine.pendingBlocks.resolve(blocks)

    await allFuturesThrowing(
      allFinished(pendingBlocks))

    await engine.stop()

asyncchecksuite "E2E - Multiple Nodes Discovery":
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
        blockDiscovery = MockDiscovery.new()
        wallet = WalletRef.example
        network = BlockExcNetwork.new(s)
        localStore = CacheStore.new()
        peerStore = PeerCtxStore.new()
        pendingBlocks = PendingBlocksManager.new()

        discovery = DiscoveryEngine.new(
          localStore,
          peerStore,
          network,
          blockDiscovery,
          pendingBlocks,
          minPeersPerBlock = 1)

        engine = BlockExcEngine.new(
          localStore,
          wallet,
          network,
          discovery,
          peerStore,
          pendingBlocks)
        networkStore = NetworkStore.new(engine, localStore)

      s.mount(network)
      switch.add(s)
      blockexc.add(networkStore)

  teardown:
    switch = @[]
    blockexc = @[]

  test "E2E - Should advertise and discover blocks":
    # Distribute the blocks amongst 1..3
    # Ask 0 to download everything without connecting him beforehand

    var advertised: Table[Cid, SignedPeerRecord]

    MockDiscovery(blockexc[1].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[1].peerInfo.signedPeerRecord

    MockDiscovery(blockexc[2].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[2].peerInfo.signedPeerRecord

    MockDiscovery(blockexc[3].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[3].peerInfo.signedPeerRecord

    await blockexc[1].engine.blocksHandler(switch[0].peerInfo.peerId, blocks[0..5])
    await blockexc[2].engine.blocksHandler(switch[0].peerInfo.peerId, blocks[4..10])
    await blockexc[3].engine.blocksHandler(switch[0].peerInfo.peerId, blocks[10..15])

    MockDiscovery(blockexc[0].engine.discovery.discovery)
      .findBlockProvidersHandler = proc(d: MockDiscovery, cid: Cid):
        Future[seq[SignedPeerRecord]] {.async.} =
        if cid in advertised:
          result.add(advertised[cid])

    let futs = collect(newSeq):
      for b in blocks:
        blockexc[0].engine.requestBlock(b.cid)

    await allFuturesThrowing(
      switch.mapIt( it.start() ) &
      blockexc.mapIt( it.engine.start() ))

    await allFutures(futs)

    await allFuturesThrowing(
      blockexc.mapIt( it.engine.stop() ) &
      switch.mapIt( it.stop() ))

  test "E2E - Should advertise and discover blocks with peers already connected":
    # Distribute the blocks amongst 1..3
    # Ask 0 to download everything without connecting him beforehand

    var advertised: Table[Cid, SignedPeerRecord]

    MockDiscovery(blockexc[1].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[1].peerInfo.signedPeerRecord

    MockDiscovery(blockexc[2].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[2].peerInfo.signedPeerRecord

    MockDiscovery(blockexc[3].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[3].peerInfo.signedPeerRecord

    await blockexc[1].engine.blocksHandler(switch[0].peerInfo.peerId, blocks[0..5])
    await blockexc[2].engine.blocksHandler(switch[0].peerInfo.peerId, blocks[4..10])
    await blockexc[3].engine.blocksHandler(switch[0].peerInfo.peerId, blocks[10..15])

    MockDiscovery(blockexc[0].engine.discovery.discovery)
      .findBlockProvidersHandler = proc(d: MockDiscovery, cid: Cid):
      Future[seq[SignedPeerRecord]] {.async.} =
        if cid in advertised:
          return @[advertised[cid]]

    let
      futs = blocks.mapIt( blockexc[0].engine.requestBlock( it.cid ) )

    await allFuturesThrowing(
      switch.mapIt( it.start() ) &
      blockexc.mapIt( it.engine.start() ))

    await allFutures(futs).wait(10.seconds)

    await allFuturesThrowing(
      blockexc.mapIt( it.engine.stop() ) &
      switch.mapIt( it.stop() ))
