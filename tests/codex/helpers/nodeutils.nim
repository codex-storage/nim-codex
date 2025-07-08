import std/sequtils
import std/sets

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import pkg/codex/discovery
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/blockexchange
import pkg/codex/merkletree
import pkg/codex/manifest
import pkg/codex/utils/safeasynciter

import ./datasetutils
import ./mockdiscovery
import ../examples
import ../../helpers

type NodesComponents* =
  tuple[
    switch: Switch,
    blockDiscovery: Discovery,
    wallet: WalletRef,
    network: BlockExcNetwork,
    localStore: BlockStore,
    peerStore: PeerCtxStore,
    pendingBlocks: PendingBlocksManager,
    discovery: DiscoveryEngine,
    engine: BlockExcEngine,
    networkStore: NetworkStore,
  ]

proc assignBlocks*(
    node: NodesComponents,
    dataset: TestDataset,
    indices: seq[int],
    putMerkleProofs = true,
): Future[void] {.async: (raises: [CatchableError]).} =
  let rootCid = dataset.tree.rootCid.tryGet()

  for i in indices:
    assert (await node.networkStore.putBlock(dataset.blocks[i])).isOk
    if putMerkleProofs:
      assert (
        await node.networkStore.putCidAndProof(
          rootCid, i, dataset.blocks[i].cid, dataset.tree.getProof(i).tryGet()
        )
      ).isOk

proc assignBlocks*(
    node: NodesComponents,
    dataset: TestDataset,
    indices: HSlice[int, int],
    putMerkleProofs = true,
): Future[void] {.async: (raises: [CatchableError]).} =
  await assignBlocks(node, dataset, indices.toSeq, putMerkleProofs)

proc assignBlocks*(
    node: NodesComponents, dataset: TestDataset, putMerkleProofs = true
): Future[void] {.async: (raises: [CatchableError]).} =
  await assignBlocks(node, dataset, 0 ..< dataset.blocks.len, putMerkleProofs)

proc generateNodes*(
    num: Natural, blocks: openArray[bt.Block] = [], enableDiscovery = true
): seq[NodesComponents] =
  for i in 0 ..< num:
    let
      switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
      discovery =
        if enableDiscovery:
          Discovery.new(
            switch.peerInfo.privateKey,
            announceAddrs =
              @[
                MultiAddress.init("/ip4/127.0.0.1/tcp/0").expect(
                  "Should return multiaddress"
                )
              ],
          )
        else:
          nullDiscovery()

    let
      wallet = WalletRef.example
      network = BlockExcNetwork.new(switch)
      localStore = CacheStore.new(blocks)
      peerStore = PeerCtxStore.new()
      pendingBlocks = PendingBlocksManager.new()
      advertiser = Advertiser.new(localStore, discovery)
      blockDiscovery =
        DiscoveryEngine.new(localStore, peerStore, network, discovery, pendingBlocks)
      engine = BlockExcEngine.new(
        localStore, wallet, network, blockDiscovery, advertiser, peerStore,
        pendingBlocks,
      )
      networkStore = NetworkStore.new(engine, localStore)

    switch.mount(network)

    let nc: NodesComponents = (
      switch, discovery, wallet, network, localStore, peerStore, pendingBlocks,
      blockDiscovery, engine, networkStore,
    )

    result.add(nc)

proc start*(nodes: NodesComponents) {.async: (raises: [CatchableError]).} =
  await allFuturesThrowing(
    nodes.switch.start(),
    #nodes.blockDiscovery.start(),
    nodes.engine.start(),
  )

proc stop*(nodes: NodesComponents) {.async: (raises: [CatchableError]).} =
  await allFuturesThrowing(
    nodes.switch.stop(),
    #   nodes.blockDiscovery.stop(),
    nodes.engine.stop(),
  )

proc start*(nodes: seq[NodesComponents]) {.async: (raises: [CatchableError]).} =
  await allFuturesThrowing(nodes.mapIt(it.start()).toSeq)

proc stop*(nodes: seq[NodesComponents]) {.async: (raises: [CatchableError]).} =
  await allFuturesThrowing(nodes.mapIt(it.stop()).toSeq)

proc connectNodes*(nodes: seq[Switch]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.connect(node.peerInfo.peerId, node.peerInfo.addrs)

proc connectNodes*(nodes: seq[NodesComponents]) {.async.} =
  await connectNodes(nodes.mapIt(it.switch))

proc connectNodes(nodes: varargs[NodesComponents]): Future[void] =
  # varargs can't be captured on closures, and async procs are closures,
  # so we have to do this mess
  let copy = nodes.toSeq
  (
    proc() {.async.} =
      await connectNodes(copy.mapIt(it.switch))
  )()

proc linearTopology*(nodes: seq[NodesComponents]) {.async.} =
  for i in 0 .. nodes.len - 2:
    await connectNodes(nodes[i], nodes[i + 1])

proc downloadDataset*(
    node: NodesComponents, dataset: TestDataset
): Future[void] {.async.} =
  # This is the same as fetchBatched, but we don't construct CodexNodes so I can't use
  # it here.
  let requestAddresses = collect:
    for i in 0 ..< dataset.manifest.blocksCount:
      BlockAddress.init(dataset.manifest.treeCid, i)

  let blockCids = dataset.blocks.mapIt(it.cid).toHashSet()

  var count = 0
  for blockFut in (await node.networkStore.getBlocks(requestAddresses)):
    let blk = (await blockFut).tryGet()
    assert blk.cid in blockCids, "Unknown block CID: " & $blk.cid
    count += 1

  assert count == dataset.blocks.len, "Incorrect number of blocks downloaded"
