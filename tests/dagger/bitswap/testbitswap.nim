import std/sequtils

import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import pkg/dagger/p2p/rng
import pkg/dagger/bitswap/bitswap
import pkg/dagger/stores/memorystore
import pkg/dagger/chunker
import pkg/dagger/blocktype as bt

import ../helpers

suite "Bitswap engine":

  let
    chunker1 = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks1 = chunker1.mapIt( bt.Block.new(it) )
    chunker2 = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks2 = chunker2.mapIt( bt.Block.new(it) )

  var
    switch1, switch2: Switch
    network1, network2: BitswapNetwork
    bitswap1, bitswap2: Bitswap
    awaiters: seq[Future[void]]
    store1, store2: MemoryStore
    peerId1, peerId2: PeerID
    done: Future[void]

  setup:
    done = newFuture[void]()

    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()
    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    peerId1 = switch1.peerInfo.peerId
    peerId2 = switch2.peerInfo.peerId

    network1 = BitswapNetwork.new(
      switch = switch1)
    switch1.mount(network1)

    store1 = MemoryStore.new(blocks1)
    bitswap1 = Bitswap.new(store1, network1)

    network2 = BitswapNetwork.new(
      switch = switch2)
    switch2.mount(network2)

    store2 = MemoryStore.new(blocks2)
    bitswap2 = Bitswap.new(store2, network2)

    await switch1.connect(
      switch2.peerInfo.peerId,
      switch2.peerInfo.addrs)

  teardown:
    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())

    await allFuturesThrowing(awaiters)

  test "should exchange want lists on connect":
    let peerCtx2 = bitswap1.engine.getPeerCtx(peerId2)
    check not isNil(peerCtx2)

    let peerCtx1 = bitswap2.engine.getPeerCtx(peerId1)
    check not isNil(peerCtx1)
