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

import ./utils
import ../helpers
import ../examples

suite "BlockExc engine - 2 nodes":

  let
    chunker1 = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks1 = chunker1.mapIt( !bt.Block.new(it) )
    chunker2 = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks2 = chunker2.mapIt( !bt.Block.new(it) )

  var
    switch1, switch2: Switch
    wallet1, wallet2: WalletRef
    pricing1, pricing2: Pricing
    network1, network2: BlockExcNetwork
    blockexc1, blockexc2: BlockExc
    awaiters: seq[Future[void]]
    peerId1, peerId2: PeerID
    peerCtx1, peerCtx2: BlockExcPeerCtx
    done: Future[void]

  setup:
    done = newFuture[void]()

    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()
    wallet1 = WalletRef.example
    wallet2 = WalletRef.example
    pricing1 = Pricing.example
    pricing2 = Pricing.example
    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    peerId1 = switch1.peerInfo.peerId
    peerId2 = switch2.peerInfo.peerId

    network1 = BlockExcNetwork.new(switch = switch1)
    blockexc1 = BlockExc.new(MemoryStore.new(blocks1), wallet1, network1)
    switch1.mount(network1)

    network2 = BlockExcNetwork.new(switch = switch2)
    blockexc2 = BlockExc.new(MemoryStore.new(blocks2), wallet2, network2)
    switch2.mount(network2)

    await allFuturesThrowing(
      blockexc1.start(),
      blockexc2.start(),
    )

    # initialize our want lists
    blockexc1.engine.wantList = blocks2.mapIt( it.cid )
    blockexc2.engine.wantList = blocks1.mapIt( it.cid )

    pricing1.address = wallet1.address
    pricing2.address = wallet2.address
    blockexc1.engine.pricing = pricing1.some
    blockexc2.engine.pricing = pricing2.some

    await switch1.connect(
      switch2.peerInfo.peerId,
      switch2.peerInfo.addrs)

    await sleepAsync(1.seconds) # give some time to exchange lists
    peerCtx2 = blockexc1.engine.getPeerCtx(peerId2)
    peerCtx1 = blockexc2.engine.getPeerCtx(peerId1)

  teardown:
    await allFuturesThrowing(
      blockexc1.stop(),
      blockexc2.stop(),
      switch1.stop(),
      switch2.stop())

    await allFuturesThrowing(awaiters)

  test "should exchange want lists on connect":
    check not isNil(peerCtx1)
    check not isNil(peerCtx2)

    check:
      peerCtx1.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        blockexc2.engine.wantList.mapIt( $it ).sorted(cmp[string])

      peerCtx2.peerHave.mapIt( $it ).sorted(cmp[string]) ==
        blockexc1.engine.wantList.mapIt( $it ).sorted(cmp[string])

  test "exchanges accounts on connect":
    check peerCtx1.account.?address == pricing1.address.some
    check peerCtx2.account.?address == pricing2.address.some

  test "should send want-have for block":
    let blk = !bt.Block.new("Block 1".toBytes)
    blockexc2.engine.localStore.putBlocks(@[blk])

    let entry = Entry(
      `block`: blk.cid.data.buffer,
      priority: 1,
      cancel: false,
      wantType: WantType.wantBlock,
      sendDontHave: false)

    peerCtx1.peerWants.add(entry)
    check blockexc2.taskQueue.pushOrUpdateNoWait(peerCtx1).isOk
    await sleepAsync(100.millis)

    check blockexc1.engine.localStore.hasBlock(blk.cid)

  test "should get blocks from remote":
    let blocks = await blockexc1.getBlocks(blocks2.mapIt( it.cid ))
    check blocks == blocks2

  test "remote should send blocks when available":
    let blk = !bt.Block.new("Block 1".toBytes)

    # should fail retrieving block from remote
    check not await blockexc1.getBlocks(@[blk.cid])
      .withTimeout(100.millis) # should expire

    proc onBlocks(evt: BlockStoreChangeEvt) =
      check evt.cids == @[blk.cid]
      done.complete()

    blockexc1.engine.localStore.addChangeHandler(onBlocks, ChangeType.Added)

    # first put the required block in the local store
    blockexc2.engine.localStore.putBlocks(@[blk])

    # second trigger blockexc to resolve any pending requests
    # for the block
    blockexc2.putBlocks(@[blk])

    await done

  test "receives payments for blocks that were sent":
    let blocks = await blockexc1.getBlocks(blocks2.mapIt(it.cid))
    await sleepAsync(100.millis)
    let channel = !peerCtx1.paymentChannel
    check wallet2.balance(channel, Asset) > 0

suite "BlockExc - multiple nodes":
  let
    chunker = newRandomChunker(Rng.instance(), size = 4096, chunkSize = 256)
    blocks = chunker.mapIt( !bt.Block.new(it) )

  var
    switch: seq[Switch]
    blockexc: seq[BlockExc]
    awaiters: seq[Future[void]]

  setup:
    for e in generateNodes(5):
      switch.add(e.switch)
      blockexc.add(e.blockexc)
      await e.blockexc.start()

    awaiters = switch.mapIt(
      (await it.start())
    ).concat()

  teardown:
    await allFuturesThrowing(
      switch.mapIt( it.stop() )
    )

    await allFuturesThrowing(awaiters)

    switch = @[]
    blockexc = @[]
    awaiters = @[]

  test "should receive haves for own want list":
    let
      downloader = blockexc[4]
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    engine.wantList &= blocks[0..3].mapIt( it.cid )
    engine.wantList &= blocks[12..15].mapIt( it.cid )

    blockexc[0].engine.localStore.putBlocks(blocks[0..3])
    blockexc[1].engine.localStore.putBlocks(blocks[4..7])
    blockexc[2].engine.localStore.putBlocks(blocks[8..11])
    blockexc[3].engine.localStore.putBlocks(blocks[12..15])

    await connectNodes(switch)
    await sleepAsync(1.seconds)

    check:
      engine.peers[0].peerHave.mapIt($it).sorted(cmp[string]) ==
        blocks[0..3].mapIt( it.cid ).mapIt($it).sorted(cmp[string])

      engine.peers[3].peerHave.mapIt($it).sorted(cmp[string]) ==
        blocks[12..15].mapIt( it.cid ).mapIt($it).sorted(cmp[string])

  test "should exchange blocks with multiple nodes":
    let
      downloader = blockexc[4]
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    engine.wantList &= blocks[0..3].mapIt( it.cid )
    engine.wantList &= blocks[12..15].mapIt( it.cid )

    blockexc[0].engine.localStore.putBlocks(blocks[0..3])
    blockexc[1].engine.localStore.putBlocks(blocks[4..7])
    blockexc[2].engine.localStore.putBlocks(blocks[8..11])
    blockexc[3].engine.localStore.putBlocks(blocks[12..15])

    await connectNodes(switch)
    await sleepAsync(1.seconds)

    let wantListBlocks = await downloader.getBlocks(blocks[0..3].mapIt( it.cid ))
    check wantListBlocks == blocks[0..3]
