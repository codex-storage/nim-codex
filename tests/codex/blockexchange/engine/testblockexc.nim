import std/sequtils
import std/algorithm

import pkg/asynctest
import pkg/chronos
import pkg/stew/byteutils

import pkg/libp2p
import pkg/libp2p/errors

import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/discovery
import pkg/codex/blocktype as bt

import ../../helpers

suite "NetworkStore engine - 2 nodes":
  let
    chunker1 = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)
    chunker2 = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)

  var
    nodeCmps1, nodeCmps2: NodesComponents
    peerCtx1, peerCtx2: BlockExcPeerCtx
    pricing1, pricing2: Pricing
    blocks1, blocks2: seq[bt.Block]
    pendingBlocks1, pendingBlocks2: seq[Future[bt.Block]]

  setup:
    while true:
      let chunk = await chunker1.getBytes()
      if chunk.len <= 0:
        break

      blocks1.add(bt.Block.new(chunk).tryGet())

    while true:
      let chunk = await chunker2.getBytes()
      if chunk.len <= 0:
        break

      blocks2.add(bt.Block.new(chunk).tryGet())

    nodeCmps1 = generateNodes(1, blocks1)[0]
    nodeCmps2 = generateNodes(1, blocks2)[0]

    await allFuturesThrowing(
      nodeCmps1.switch.start(),
      nodeCmps1.blockDiscovery.start(),
      nodeCmps1.engine.start(),
      nodeCmps2.switch.start(),
      nodeCmps2.blockDiscovery.start(),
      nodeCmps2.engine.start())

    # initialize our want lists
    pendingBlocks1 = blocks2.mapIt( nodeCmps1.pendingBlocks.getWantHandle( it.cid ) )
    pendingBlocks2 = blocks1.mapIt( nodeCmps2.pendingBlocks.getWantHandle( it.cid ) )

    pricing1.address = nodeCmps1.wallet.address
    pricing2.address = nodeCmps2.wallet.address
    nodeCmps1.engine.pricing = pricing1.some
    nodeCmps2.engine.pricing = pricing2.some

    await nodeCmps1.switch.connect(
      nodeCmps2.switch.peerInfo.peerId,
      nodeCmps2.switch.peerInfo.addrs)

    await sleepAsync(1.seconds) # give some time to exchange lists
    peerCtx2 = nodeCmps1.peerStore.get(nodeCmps2.switch.peerInfo.peerId)
    peerCtx1 = nodeCmps2.peerStore.get(nodeCmps1.switch.peerInfo.peerId)

    check isNil(peerCtx1).not
    check isNil(peerCtx2).not

  teardown:
    await allFuturesThrowing(
      nodeCmps1.blockDiscovery.stop(),
      nodeCmps1.engine.stop(),
      nodeCmps1.switch.stop(),
      nodeCmps2.blockDiscovery.stop(),
      nodeCmps2.engine.stop(),
      nodeCmps2.switch.stop())

  test "Should exchange want lists on connect":
    await allFuturesThrowing(
      allFinished(pendingBlocks1))
      .wait(10.seconds)

    await allFuturesThrowing(
      allFinished(pendingBlocks2))
      .wait(10.seconds)

    check:
      peerCtx1.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        pendingBlocks2.mapIt( $it.read.cid ).sorted(cmp[string])

      peerCtx2.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        pendingBlocks1.mapIt( $it.read.cid ).sorted(cmp[string])

  test "Should exchanges accounts on connect":
    check peerCtx1.account.?address == pricing1.address.some
    check peerCtx2.account.?address == pricing2.address.some

  test "Should send want-have for block":
    let blk = bt.Block.new("Block 1".toBytes).tryGet()
    check await nodeCmps2.localStore.putBlock(blk)

    let entry = Entry(
      `block`: blk.cid.data.buffer,
      priority: 1,
      cancel: false,
      wantType: WantType.wantBlock,
      sendDontHave: false)

    peerCtx1.peerWants.add(entry)
    check nodeCmps2
      .engine
      .taskQueue
      .pushOrUpdateNoWait(peerCtx1).isOk

    check eventually nodeCmps1.localStore.hasBlock(blk.cid)

  test "Should get blocks from remote":
    let blocks = await allFinished(
      blocks2.mapIt( nodeCmps1.networkStore.getBlock(it.cid) ))
    check blocks.mapIt( !it.read ) == blocks2

  test "Remote should send blocks when available":
    let blk = bt.Block.new("Block 1".toBytes).tryGet()

    # should fail retrieving block from remote
    check not await nodeCmps1.networkStore.getBlock(blk.cid)
      .withTimeout(100.millis) # should expire

    # second trigger blockexc to resolve any pending requests
    # for the block
    check await nodeCmps2.networkStore.putBlock(blk)

    # should succeed retrieving block from remote
    check await nodeCmps1.networkStore.getBlock(blk.cid)
      .withTimeout(100.millis) # should succeed

  test "Should receive payments for blocks that were sent":
    let blocks = await allFinished(
      blocks2.mapIt( nodeCmps1.networkStore.getBlock(it.cid) ))

    let channel = !peerCtx1.paymentChannel
    let wallet = nodeCmps2.wallet

    check eventually wallet.balance(channel, Asset) > 0

suite "NetworkStore - multiple nodes":
  let
    chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    switch: seq[Switch]
    networkStore: seq[NetworkStore]
    blocks: seq[bt.Block]

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    for e in generateNodes(5):
      switch.add(e.switch)
      networkStore.add(e.networkStore)
      await e.engine.start()

    await allFuturesThrowing(
      switch.mapIt( it.start() )
    )

  teardown:
    await allFuturesThrowing(
      switch.mapIt( it.stop() )
    )

    switch = @[]
    networkStore = @[]

  test "Should receive haves for own want list":
    let
      downloader = networkStore[4]
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    let
      pendingBlocks1 = blocks[0..3].mapIt( engine.pendingBlocks.getWantHandle( it.cid ) )
      pendingBlocks2 = blocks[12..15].mapIt( engine.pendingBlocks.getWantHandle( it.cid ))

    await allFutures(
      blocks[0..3].mapIt( networkStore[0].engine.localStore.putBlock(it) ))
    await allFutures(
      blocks[4..7].mapIt( networkStore[1].engine.localStore.putBlock(it) ))
    await allFutures(
      blocks[8..11].mapIt( networkStore[2].engine.localStore.putBlock(it) ))
    await allFutures(
      blocks[12..15].mapIt( networkStore[3].engine.localStore.putBlock(it) ))

    await connectNodes(switch)
    await sleepAsync(1.seconds)

    await allFuturesThrowing(
      allFinished(pendingBlocks1),
      allFinished(pendingBlocks2))

    let
      peers = toSeq(engine.peers)

    check:
      peers[0].peerHave.mapIt($it).sorted(cmp[string]) ==
        blocks[0..3].mapIt( $(it.cid) ).sorted(cmp[string])

      peers[3].peerHave.mapIt($it).sorted(cmp[string]) ==
        blocks[12..15].mapIt( $(it.cid) ).sorted(cmp[string])

  test "Should exchange blocks with multiple nodes":
    let
      downloader = networkStore[4]
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    let
      pendingBlocks1 = blocks[0..3].mapIt( engine.pendingBlocks.getWantHandle( it.cid ) )
      pendingBlocks2 = blocks[12..15].mapIt( engine.pendingBlocks.getWantHandle( it.cid ))

    await allFutures(
      blocks[0..3].mapIt( networkStore[0].engine.localStore.putBlock(it) ))
    await allFutures(
      blocks[4..7].mapIt( networkStore[1].engine.localStore.putBlock(it) ))
    await allFutures(
      blocks[8..11].mapIt( networkStore[2].engine.localStore.putBlock(it) ))
    await allFutures(
      blocks[12..15].mapIt( networkStore[3].engine.localStore.putBlock(it) ))

    await connectNodes(switch)
    await sleepAsync(1.seconds)

    await allFuturesThrowing(
      allFinished(pendingBlocks1),
      allFinished(pendingBlocks2))

    check pendingBlocks1.mapIt( it.read ) == blocks[0..3]
    check pendingBlocks2.mapIt( it.read ) == blocks[12..15]
