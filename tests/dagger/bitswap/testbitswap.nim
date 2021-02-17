
import std/sets
import std/sequtils
import std/algorithm

import pkg/asynctest
import pkg/chronos
import pkg/stew/byteutils
import pkg/libp2p
import pkg/libp2p/errors

import pkg/dagger/p2p/rng
import pkg/dagger/bitswap
import pkg/dagger/stores/memorystore
import pkg/dagger/chunker
import pkg/dagger/blocktype as bt
import pkg/dagger/utils/asyncheapqueue

import ./utils
import ../helpers

suite "Bitswap engine - 2 nodes":

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

    network1 = BitswapNetwork.new(switch = switch1)
    bitswap1 = Bitswap.new(MemoryStore.new(blocks1), network1)
    switch1.mount(network1)

    network2 = BitswapNetwork.new(switch = switch2)
    bitswap2 = Bitswap.new(MemoryStore.new(blocks2), network2)
    switch2.mount(network2)

    await allFuturesThrowing(
      bitswap1.start(),
      bitswap2.start(),
    )

    # initialize our want lists
    bitswap1.engine.wantList = blocks2.mapIt( it.cid )
    bitswap2.engine.wantList = blocks1.mapIt( it.cid )

    await switch1.connect(
      switch2.peerInfo.peerId,
      switch2.peerInfo.addrs)

    await sleepAsync(1.seconds) # give some time to exchange lists
    peerCtx2 = bitswap1.engine.getPeerCtx(peerId2)
    peerCtx1 = bitswap2.engine.getPeerCtx(peerId1)

  teardown:
    await allFuturesThrowing(
      bitswap1.stop(),
      bitswap2.stop(),
      switch1.stop(),
      switch2.stop())

    await allFuturesThrowing(awaiters)

  test "should exchange want lists on connect":
    check not isNil(peerCtx1)
    check not isNil(peerCtx2)

    check:
      peerCtx1.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        bitswap2.engine.wantList.mapIt( $it ).sorted(cmp[string])

      peerCtx2.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        bitswap1.engine.wantList.mapIt( $it ).sorted(cmp[string])

  test "should send want-have for block":
    let blk = bt.Block.new("Block 1".toBytes)
    bitswap2.engine.localStore.putBlocks(@[blk])

    let entry = Entry(
      `block`: blk.cid.data.buffer,
      priority: 1,
      cancel: false,
      wantType: WantType.wantBlock,
      sendDontHave: false)

    peerCtx1.peerWants.add(entry)
    check bitswap2.taskQueue.pushOrUpdateNoWait(peerCtx1).isOk
    await sleepAsync(100.millis)

    check bitswap1.engine.localStore.hasBlock(blk.cid)

  test "should get blocks from remote":
    let blocks = await bitswap1.getBlocks(blocks2.mapIt( it.cid ))
    check blocks == blocks2

  test "remote should send blocks when available":
    let blk = bt.Block.new("Block 1".toBytes)

    # should fail retrieving block from remote
    var blocks = await bitswap1.getBlocks(@[blk.cid])
    check blocks.len == 0

    proc onBlocks(evt: BlockStoreChangeEvt) =
      check evt.cids == @[blk.cid]
      done.complete()

    bitswap1.engine.localStore.addChangeHandler(onBlocks, ChangeType.Added)

    # first put the required block in the local store
    bitswap2.engine.localStore.putBlocks(@[blk])

    # second trigger bitswap to resolve any pending requests
    # for the block
    bitswap2.putBlocks(@[blk])

    await done

suite "Bitswap - multiple nodes":
  let
    chunker = newRandomChunker(Rng.instance(), size = 4096, chunkSize = 256)
    blocks = chunker.mapIt( bt.Block.new(it) )

  var
    switch: seq[Switch]
    bitswap: seq[Bitswap]
    awaiters: seq[Future[void]]

  setup:
    for e in generateNodes(5):
      switch.add(e.switch)
      bitswap.add(e.bitswap)
      await e.bitswap.start()

    awaiters = switch.mapIt(
      (await it.start())
    ).concat()

  teardown:
    await allFuturesThrowing(
      switch.mapIt( it.stop() )
    )

    await allFuturesThrowing(awaiters)

  test "should receive haves for own want list":
    let
      downloader = bitswap[4]
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    engine.wantList &= blocks[0..3].mapIt( it.cid )
    engine.wantList &= blocks[12..15].mapIt( it.cid )

    bitswap[0].engine.localStore.putBlocks(blocks[0..3])
    bitswap[1].engine.localStore.putBlocks(blocks[4..7])
    bitswap[2].engine.localStore.putBlocks(blocks[8..11])
    bitswap[3].engine.localStore.putBlocks(blocks[12..15])

    await connectNodes(switch)

    await sleepAsync(1.seconds)
    check engine.peers[0].peerHave == blocks[0..3].mapIt( it.cid )
    check engine.peers[3].peerHave == blocks[12..15].mapIt( it.cid )

  test "should exchange blocks with multiple nodes":
    let
      downloader = bitswap[4]
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    engine.wantList &= blocks[0..3].mapIt( it.cid )
    engine.wantList &= blocks[12..15].mapIt( it.cid )

    bitswap[0].engine.localStore.putBlocks(blocks[0..3])
    bitswap[1].engine.localStore.putBlocks(blocks[4..7])
    bitswap[2].engine.localStore.putBlocks(blocks[8..11])
    bitswap[3].engine.localStore.putBlocks(blocks[12..15])

    await connectNodes(switch)
    let wantListBlocks = await downloader.getBlocks(blocks[0..3].mapIt( it.cid ))
    check wantListBlocks == blocks[0..3]
