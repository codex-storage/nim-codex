import std/sequtils
import std/sugar
import std/tables

import pkg/asynctest

import pkg/chronos
import pkg/chronicles
import pkg/libp2p

import pkg/dagger/rng
import pkg/dagger/stores
import pkg/dagger/blockexchange
import pkg/dagger/chunker
import pkg/dagger/blocktype as bt
import pkg/dagger/blockexchange/engine

import ./mockdiscovery

import ../../helpers
import ../../examples

suite "Test Discovery Engine":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    blocks: seq[bt.Block]
    switch: Switch
    peerStore: PeerCtxStore
    blockDiscovery: MockDiscovery
    pendingBlocks: PendingBlocksManager
    localStore: CacheStore
    network: BlockExcNetwork

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
    network = BlockExcNetwork.new(switch)
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    blockDiscovery = MockDiscovery.new()

  test "Should Query Wants":
    var
      localStore = CacheStore.new()
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis)
      wants = blocks.mapIt( pendingBlocks.getWantHandle(it.cid) )

    blockDiscovery.findBlockProvidersHandler =
      proc(d: MockDiscovery, cid: Cid): Future[seq[SignedPeerRecord]] {.async, gcsafe.} =
        pendingBlocks.resolve(blocks.filterIt( it.cid == cid))

    await discoveryEngine.start()
    await allFuturesThrowing(allFinished(wants)).wait(1.seconds)
    await discoveryEngine.stop()

  test "Should Advertise Haves":
    var
      localStore = CacheStore.new(blocks.mapIt( it ))
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis)
      haves = collect(initTable):
        for b in blocks:
          { b.cid: newFuture[void]() }

    blockDiscovery.publishProvideHandler =
      proc(d: MockDiscovery, cid: Cid) {.async, gcsafe.} =
        if not haves[cid].finished:
          haves[cid].complete

    await discoveryEngine.start()
    await allFuturesThrowing(
      allFinished(toSeq(haves.values))).wait(1.seconds)
    await discoveryEngine.stop()

  test "Should queue discovery request":
    var
      localStore = CacheStore.new()
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis)
      want = newFuture[void]()

    blockDiscovery.findBlockProvidersHandler =
      proc(d: MockDiscovery, cid: Cid): Future[seq[SignedPeerRecord]] {.async, gcsafe.} =
        check cid == blocks[0].cid
        if not want.finished:
          want.complete()

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await want.wait(1.seconds)
    await discoveryEngine.stop()

  test "Should queue advertise request":
    var
      localStore = CacheStore.new(@[blocks[0]])
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis)
      have = newFuture[void]()

    blockDiscovery.publishProvideHandler =
      proc(d: MockDiscovery, cid: Cid) {.async, gcsafe.} =
        check cid == blocks[0].cid
        if not have.finished:
          have.complete()

    await discoveryEngine.start()
    await have.wait(1.seconds)
    await discoveryEngine.stop()

  test "Should not request more than minPeersPerBlock":
    var
      localStore = CacheStore.new()
      minPeers = 2
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 5.minutes,
        minPeersPerBlock = minPeers)
      want = newAsyncEvent()

    blockDiscovery.findBlockProvidersHandler =
      proc(d: MockDiscovery, cid: Cid): Future[seq[SignedPeerRecord]] {.async, gcsafe.} =
        check cid == blocks[0].cid
        check peerStore.len < minPeers
        var
          peerCtx = BlockExcPeerCtx(id: PeerID.example)

        peerCtx.peerPrices[cid] = 0.u256
        peerStore.add(peerCtx)
        want.fire()

    await discoveryEngine.start()
    while peerStore.len < minPeers:
      discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
      await want.wait()
      want.clear()

    check peerStore.len == minPeers
    await discoveryEngine.stop()

  test "Should not request if there is already an inflight discovery request":
    var
      localStore = CacheStore.new()
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
        concurrentDiscReqs = 2)
      reqs = newFuture[void]()
      count = 0

    blockDiscovery.findBlockProvidersHandler =
      proc(d: MockDiscovery, cid: Cid):
        Future[seq[SignedPeerRecord]] {.gcsafe, async.} =
        check cid == blocks[0].cid
        if count > 0:
          check false
        count.inc

        await reqs # queue the request

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    reqs.complete()
    await discoveryEngine.stop()

  test "Should not request if there is already an inflight advertise request":
    var
      localStore = CacheStore.new()
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
        concurrentAdvReqs = 2)
      reqs = newFuture[void]()
      count = 0

    blockDiscovery.publishProvideHandler =
      proc(d: MockDiscovery, cid: Cid) {.async, gcsafe.} =
        check cid == blocks[0].cid
        if count > 0:
          check false
        count.inc

        await reqs # queue the request

    await discoveryEngine.start()
    discoveryEngine.queueProvideBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    discoveryEngine.queueProvideBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    reqs.complete()
    await discoveryEngine.stop()
