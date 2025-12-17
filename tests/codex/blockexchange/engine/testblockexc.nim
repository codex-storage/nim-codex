import std/sequtils
import std/algorithm
import std/importutils

import pkg/chronos
import pkg/stew/byteutils

import pkg/codex/stores
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/discovery
import pkg/codex/blocktype as bt

import ../../../asynctest
import ../../examples
import ../../helpers

asyncchecksuite "NetworkStore engine - 2 nodes":
  var
    nodeCmps1, nodeCmps2: NodesComponents
    peerCtx1, peerCtx2: BlockExcPeerCtx
    blocks1, blocks2: seq[bt.Block]
    pendingBlocks1, pendingBlocks2: seq[BlockHandle]

  setup:
    blocks1 = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
    blocks2 = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
    nodeCmps1 = generateNodes(1, blocks1).components[0]
    nodeCmps2 = generateNodes(1, blocks2).components[0]

    await allFuturesThrowing(nodeCmps1.start(), nodeCmps2.start())

    # initialize our want lists
    pendingBlocks1 =
      blocks2[0 .. 3].mapIt(nodeCmps1.pendingBlocks.getWantHandle(it.cid))

    pendingBlocks2 =
      blocks1[0 .. 3].mapIt(nodeCmps2.pendingBlocks.getWantHandle(it.cid))

    await nodeCmps1.switch.connect(
      nodeCmps2.switch.peerInfo.peerId, nodeCmps2.switch.peerInfo.addrs
    )

    await sleepAsync(100.millis) # give some time to exchange lists
    peerCtx2 = nodeCmps1.peerStore.get(nodeCmps2.switch.peerInfo.peerId)
    peerCtx1 = nodeCmps2.peerStore.get(nodeCmps1.switch.peerInfo.peerId)

    check isNil(peerCtx1).not
    check isNil(peerCtx2).not

  teardown:
    await allFuturesThrowing(nodeCmps1.stop(), nodeCmps2.stop())

  test "Should exchange blocks on connect":
    await allFuturesThrowing(allFinished(pendingBlocks1)).wait(10.seconds)
    await allFuturesThrowing(allFinished(pendingBlocks2)).wait(10.seconds)

    check:
      (await allFinished(blocks1[0 .. 3].mapIt(nodeCmps2.localStore.getBlock(it.cid))))
      .filterIt(it.completed and it.read.isOk)
      .mapIt($it.read.get.cid)
      .sorted(cmp[string]) == blocks1[0 .. 3].mapIt($it.cid).sorted(cmp[string])

      (await allFinished(blocks2[0 .. 3].mapIt(nodeCmps1.localStore.getBlock(it.cid))))
      .filterIt(it.completed and it.read.isOk)
      .mapIt($it.read.get.cid)
      .sorted(cmp[string]) == blocks2[0 .. 3].mapIt($it.cid).sorted(cmp[string])

  test "Should send want-have for block":
    let blk = bt.Block.new("Block 1".toBytes).tryGet()
    let blkFut = nodeCmps1.pendingBlocks.getWantHandle(blk.cid)
    peerCtx2.blockRequestScheduled(blk.address)

    (await nodeCmps2.localStore.putBlock(blk)).tryGet()

    peerCtx1.wantedBlocks.incl(blk.address)
    check nodeCmps2.engine.taskQueue.pushOrUpdateNoWait(peerCtx1).isOk

    check eventually (await nodeCmps1.localStore.hasBlock(blk.cid)).tryGet()
    check eventually (await blkFut) == blk

  test "Should get blocks from remote":
    let blocks =
      await allFinished(blocks2[4 .. 7].mapIt(nodeCmps1.networkStore.getBlock(it.cid)))

    check blocks.mapIt(it.read().tryGet()) == blocks2[4 .. 7]

  test "Remote should send blocks when available":
    let blk = bt.Block.new("Block 1".toBytes).tryGet()

    # should fail retrieving block from remote
    check not await blk.cid in nodeCmps1.networkStore

    # second trigger blockexc to resolve any pending requests
    # for the block
    (await nodeCmps2.networkStore.putBlock(blk)).tryGet()

    # should succeed retrieving block from remote
    check await nodeCmps1.networkStore.getBlock(blk.cid).withTimeout(100.millis)
      # should succeed

asyncchecksuite "NetworkStore - multiple nodes":
  var
    nodes: seq[NodesComponents]
    blocks: seq[bt.Block]

  setup:
    blocks = await makeRandomBlocks(datasetSize = 4096, blockSize = 256'nb)
    nodes = generateNodes(5)
    for e in nodes:
      await e.engine.start()

    await allFuturesThrowing(nodes.mapIt(it.switch.start()))

  teardown:
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

    nodes = @[]

  test "Should receive blocks for own want list":
    let
      downloader = nodes[4].networkStore
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    let
      downloadCids = blocks[0 .. 3].mapIt(it.cid) & blocks[12 .. 15].mapIt(it.cid)

      pendingBlocks = downloadCids.mapIt(engine.pendingBlocks.getWantHandle(it))

    for i in 0 .. 15:
      (await nodes[i div 4].networkStore.engine.localStore.putBlock(blocks[i])).tryGet()

    await connectNodes(nodes)
    await sleepAsync(100.millis)

    await allFuturesThrowing(allFinished(pendingBlocks))

    check:
      (await allFinished(downloadCids.mapIt(downloader.localStore.getBlock(it))))
      .filterIt(it.completed and it.read.isOk)
      .mapIt($it.read.get.cid)
      .sorted(cmp[string]) == downloadCids.mapIt($it).sorted(cmp[string])

  test "Should exchange blocks with multiple nodes":
    let
      downloader = nodes[4].networkStore
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    let
      pendingBlocks1 = blocks[0 .. 3].mapIt(engine.pendingBlocks.getWantHandle(it.cid))
      pendingBlocks2 =
        blocks[12 .. 15].mapIt(engine.pendingBlocks.getWantHandle(it.cid))

    for i in 0 .. 15:
      (await nodes[i div 4].networkStore.engine.localStore.putBlock(blocks[i])).tryGet()

    await connectNodes(nodes)
    await sleepAsync(100.millis)

    await allFuturesThrowing(allFinished(pendingBlocks1), allFinished(pendingBlocks2))

    check pendingBlocks1.mapIt(it.read) == blocks[0 .. 3]
    check pendingBlocks2.mapIt(it.read) == blocks[12 .. 15]

asyncchecksuite "NetworkStore - dissemination":
  var nodes: seq[NodesComponents]

  teardown:
    if nodes.len > 0:
      await nodes.stop()

  test "Should disseminate blocks across large diameter swarm":
    let dataset = makeDataset(await makeRandomBlocks(60 * 256, 256'nb)).tryGet()

    nodes = generateNodes(
      6,
      config = NodeConfig(
        useRepoStore: false,
        findFreePorts: false,
        basePort: 8080,
        createFullNode: false,
        enableBootstrap: false,
        enableDiscovery: true,
      ),
    )

    await assignBlocks(nodes[0], dataset, 0 .. 9)
    await assignBlocks(nodes[1], dataset, 10 .. 19)
    await assignBlocks(nodes[2], dataset, 20 .. 29)
    await assignBlocks(nodes[3], dataset, 30 .. 39)
    await assignBlocks(nodes[4], dataset, 40 .. 49)
    await assignBlocks(nodes[5], dataset, 50 .. 59)

    await nodes.start()
    await nodes.linearTopology()

    let downloads = nodes.mapIt(downloadDataset(it, dataset))
    await allFuturesThrowing(downloads).wait(30.seconds)
