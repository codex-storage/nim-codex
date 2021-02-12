import std/sequtils
import std/algorithm

import pkg/asynctest
import pkg/chronos
import pkg/stew/byteutils
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
    peerCtx1, peerCtx2: BitswapPeerCtx
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

    await allFuturesThrowing(
      bitswap1.start(),
      bitswap2.start(),
    )

    # initialize our want lists
    bitswap1.wantList = blocks2.mapIt( it.cid )
    bitswap2.wantList = blocks1.mapIt( it.cid )

    await switch1.connect(
      switch2.peerInfo.peerId,
      switch2.peerInfo.addrs)

    await sleepAsync(1.seconds) # give some time to exchange lists
    peerCtx2 = bitswap1.getPeerCtx(peerId2)
    peerCtx1 = bitswap2.getPeerCtx(peerId1)

  teardown:
    await allFuturesThrowing(
      bitswap1.start(),
      bitswap2.start(),
      switch1.stop(),
      switch2.stop())

    await allFuturesThrowing(awaiters)

  test "should exchange want lists on connect":
    check not isNil(peerCtx1)
    check not isNil(peerCtx2)

    check:
      peerCtx1.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        bitswap2.wantList.mapIt( $it ).sorted(cmp[string])

      peerCtx2.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        bitswap1.wantList.mapIt( $it ).sorted(cmp[string])

  test "should send want-have for block":
    let blk = bt.Block.new("Block 1".toBytes)
    store2.putBlocks(@[blk])

    let entry = Entry(
      `block`: blk.cid.data.buffer,
      priority: 1,
      cancel: false,
      wantType: WantType.wantBlock,
      sendDontHave: false)

    check peerCtx1.peerWants.pushOrUpdateNoWait(entry).isOk
    check bitswap2.taskQueue.pushOrUpdateNoWait(peerCtx1).isOk
    await sleepAsync(10.seconds)
