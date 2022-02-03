import std/sequtils
import std/algorithm

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

import ../helpers
import ../examples

suite "Block exchange engine - 2 nodes":

  let
    chunker1 = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)
    chunker2 = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)

  var
    switch1, switch2: Switch
    wallet1, wallet2: WalletRef
    pricing1, pricing2: Pricing
    network1, network2: BlockExcNetwork
    peerId1, peerId2: PeerID
    peerCtx1, peerCtx2: BlockExcPeerCtx
    blocks1, blocks2: seq[bt.Block]
    engine1, engine2: BlockExcEngine
    localStore1, localStore2: BlockStore
    blockStoreMgr1, blockStoreMgr2: BlockStoreManager

  setup:
    while true:
      let chunk = await chunker1.getBytes()
      if chunk.len <= 0:
        break

      blocks1.add(bt.Block.init(chunk).tryGet())

    while true:
      let chunk = await chunker2.getBytes()
      if chunk.len <= 0:
        break

      blocks2.add(bt.Block.init(chunk).tryGet())

    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()
    wallet1 = WalletRef.example
    wallet2 = WalletRef.example
    pricing1 = Pricing.example
    pricing2 = Pricing.example
    await switch1.start()
    await switch2.start()

    peerId1 = switch1.peerInfo.peerId
    peerId2 = switch2.peerInfo.peerId

    localStore1 = MemoryStore.new(blocks1.mapIt( it ))
    network1 = BlockExcNetwork.new(switch = switch1)
    blockStoreMgr1 = BlockStoreManager.new(@[localStore1])
    engine1 = BlockExcEngine.new(wallet1, network1, blockStoreMgr1)
    switch1.mount(network1)

    localStore2 = MemoryStore.new(blocks2.mapIt( it ))
    network2 = BlockExcNetwork.new(switch = switch2)
    blockStoreMgr2 = BlockStoreManager.new(@[localStore2])
    engine2 = BlockExcEngine.new(wallet2, network2, blockStoreMgr2)
    switch2.mount(network2)

    await allFuturesThrowing(
      engine1.start(),
      engine2.start(),
    )

    # initialize our want lists
    engine1.wantList = blocks2.mapIt( it.cid )
    engine2.wantList = blocks1.mapIt( it.cid )

    pricing1.address = wallet1.address
    pricing2.address = wallet2.address
    engine1.pricing = pricing1.some
    engine2.pricing = pricing2.some

    await switch1.connect(
      switch2.peerInfo.peerId,
      switch2.peerInfo.addrs)

    await sleepAsync(1.seconds) # give some time to exchange lists
    peerCtx2 = engine1.getPeerCtx(peerId2)
    peerCtx1 = engine2.getPeerCtx(peerId1)

  teardown:
    await allFuturesThrowing(
      engine1.stop(),
      engine2.stop(),
      switch1.stop(),
      switch2.stop())

  test "should exchange want lists on connect":
    check not isNil(peerCtx1)
    check not isNil(peerCtx2)

    check:
      peerCtx1.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        engine2.wantList.mapIt( $it ).sorted(cmp[string])

      peerCtx2.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        engine1.wantList.mapIt( $it ).sorted(cmp[string])

  test "exchanges accounts on connect":
    check peerCtx1.account.?address == pricing1.address.some
    check peerCtx2.account.?address == pricing2.address.some

  test "should send want-have for block":
    let blk = bt.Block.init("Block 1".toBytes).tryGet()
    check await engine2.store(blk)

    let entry = Entry(
      `block`: blk.cid.data.buffer,
      priority: 1,
      cancel: false,
      wantType: WantType.wantBlock,
      sendDontHave: false)

    peerCtx1.peerWants.add(entry)
    check engine2
      .taskQueue
      .pushOrUpdateNoWait(peerCtx1).isOk
    await sleepAsync(100.millis)

    check engine1.exists(blk.cid)

  test "should get blocks from remote":
    let blocks = await allFinished(
      blocks2.mapIt( engine1.retrieve(it.cid) ))
    check blocks.mapIt( !it.read ) == blocks2

  test "remote should send blocks when available":
    let blk = bt.Block.init("Block 1".toBytes).tryGet()

    # should fail retrieving block from remote
    check not await engine1.retrieve(blk.cid)
      .withTimeout(100.millis) # should expire

    # First, put the required block in the local store.
    check await engine2.store(blk)
    # Second, trigger blockexc to resolve any pending requests for the block.
    engine2.resolveBlocks(@[blk])

    # should succeed retrieving block from remote
    check await engine1.retrieve(blk.cid)
      .withTimeout(100.millis) # should succede

  test "receives payments for blocks that were sent":
    let blocks = await allFinished(
      blocks2.mapIt( engine1.retrieve(it.cid) ))
    await sleepAsync(100.millis)
    let channel = !peerCtx1.paymentChannel
    check wallet2.balance(channel, Asset) > 0

suite "Block exchange engine - multiple nodes":
  let
    chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    switch: seq[Switch]
    blockexc: seq[BlockExcEngine]
    blocks: seq[bt.Block]

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.init(chunk).tryGet())

    for e in generateNodes(5):
      switch.add(e.switch)
      blockexc.add(e.blockexc)
      await e.blockexc.start()

    await allFuturesThrowing(
      switch.mapIt( it.start() )
    )

  teardown:
    await allFuturesThrowing(
      switch.mapIt( it.stop() )
    )

    switch = @[]
    blockexc = @[]

  test "should receive haves for own want list":
    let engine = blockexc[4]

    # Add blocks from 1st peer to want list
    engine.wantList &= blocks[0..3].mapIt( it.cid )
    engine.wantList &= blocks[12..15].mapIt( it.cid )

    await allFutures(
      blocks[0..3].mapIt( blockexc[0].store(it) ))
    await allFutures(
      blocks[4..7].mapIt( blockexc[1].store(it) ))
    await allFutures(
      blocks[8..11].mapIt( blockexc[2].store(it) ))
    await allFutures(
      blocks[12..15].mapIt( blockexc[3].store(it) ))

    await connectNodes(switch)
    await sleepAsync(1.seconds)

    check:
      engine.peers[0].peerHave.mapIt($it).sorted(cmp[string]) ==
        blocks[0..3].mapIt( it.cid ).mapIt($it).sorted(cmp[string])

      engine.peers[3].peerHave.mapIt($it).sorted(cmp[string]) ==
        blocks[12..15].mapIt( it.cid ).mapIt($it).sorted(cmp[string])

  test "should exchange blocks with multiple nodes":
    let engine = blockexc[4]

    # Add blocks from 1st peer to want list
    engine.wantList &= blocks[0..3].mapIt( it.cid )
    engine.wantList &= blocks[12..15].mapIt( it.cid )

    await allFutures(
      blocks[0..3].mapIt( blockexc[0].store(it) ))
    await allFutures(
      blocks[4..7].mapIt( blockexc[1].store(it) ))
    await allFutures(
      blocks[8..11].mapIt( blockexc[2].store(it) ))
    await allFutures(
      blocks[12..15].mapIt( blockexc[3].store(it) ))

    await connectNodes(switch)
    await sleepAsync(1.seconds)

    let wantListBlocks = await allFinished(
      blocks[0..3].mapIt( engine.retrieve(it.cid) ))
    check wantListBlocks.mapIt( !it.read ) == blocks[0..3]
