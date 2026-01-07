import std/sequtils
import std/random
import std/algorithm

import pkg/stew/byteutils
import pkg/chronos
import pkg/libp2p/errors
import pkg/libp2p/routing_record
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/rng
import pkg/codex/blockexchange
import pkg/codex/stores
import pkg/codex/chunker
import pkg/codex/discovery
import pkg/codex/blocktype
import pkg/codex/utils/asyncheapqueue

import ../../../asynctest
import ../../helpers
import ../../examples

const NopSendWantCancellationsProc = proc(
    id: PeerId, addresses: seq[BlockAddress]
) {.async: (raises: [CancelledError]).} =
  discard

asyncchecksuite "NetworkStore engine basic":
  var
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    blocks: seq[Block]
    done: Future[void]

  setup:
    peerId = PeerId.example
    chunker = RandomChunker.new(Rng.instance(), size = 1024'nb, chunkSize = 256'nb)
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    done = newFuture[void]()

  test "Should send want list to new peers":
    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      check addresses.mapIt($it.cidOrTreeCid).sorted == blocks.mapIt($it.cid).sorted
      done.complete()

    let
      network = BlockExcNetwork(request: BlockExcRequest(sendWantList: sendWantList))
      localStore = CacheStore.new(blocks.mapIt(it))
      discovery = DiscoveryEngine.new(
        localStore, peerStore, network, blockDiscovery, pendingBlocks
      )
      advertiser = Advertiser.new(localStore, blockDiscovery)
      engine = BlockExcEngine.new(
        localStore, network, discovery, advertiser, peerStore, pendingBlocks
      )

    for b in blocks:
      discard engine.pendingBlocks.getWantHandle(b.cid)
    await engine.peerAddedHandler(peerId)

    await done.wait(100.millis)

asyncchecksuite "NetworkStore engine handlers":
  var
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    advertiser: Advertiser
    peerCtx: BlockExcPeerCtx
    localStore: BlockStore
    blocks: seq[Block]

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = 1024'nb, chunkSize = 256'nb)

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    peerId = PeerId.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    localStore = CacheStore.new()
    network = BlockExcNetwork()

    discovery =
      DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)

    advertiser = Advertiser.new(localStore, blockDiscovery)

    engine = BlockExcEngine.new(
      localStore, network, discovery, advertiser, peerStore, pendingBlocks
    )

    peerCtx = BlockExcPeerCtx(id: peerId)
    engine.peers.add(peerCtx)

  test "Should schedule block requests":
    let wantList = makeWantList(blocks.mapIt(it.cid), wantType = WantType.WantBlock)
      # only `wantBlock` are stored in `peerWants`

    proc handler() {.async.} =
      let ctx = await engine.taskQueue.pop()
      check ctx.id == peerId
      # only `wantBlock` scheduled
      check ctx.wantedBlocks == blocks.mapIt(it.address).toHashSet

    let done = handler()
    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list":
    let
      done = newFuture[void]()
      wantList = makeWantList(blocks.mapIt(it.cid))

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      check presence.mapIt(it.address) == wantList.entries.mapIt(it.address)
      done.complete()

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    await allFuturesThrowing(allFinished(blocks.mapIt(localStore.putBlock(it))))

    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list - `dont-have`":
    let
      done = newFuture[void]()
      wantList = makeWantList(blocks.mapIt(it.cid), sendDontHave = true)

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      check presence.mapIt(it.address) == wantList.entries.mapIt(it.address)
      for p in presence:
        check:
          p.`type` == BlockPresenceType.DontHave

      done.complete()

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list - `dont-have` some blocks":
    let
      done = newFuture[void]()
      wantList = makeWantList(blocks.mapIt(it.cid), sendDontHave = true)

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      for p in presence:
        if p.address.cidOrTreeCid != blocks[0].cid and
            p.address.cidOrTreeCid != blocks[1].cid:
          check p.`type` == BlockPresenceType.DontHave
        else:
          check p.`type` == BlockPresenceType.Have

      done.complete()

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    (await engine.localStore.putBlock(blocks[0])).tryGet()
    (await engine.localStore.putBlock(blocks[1])).tryGet()
    await engine.wantListHandler(peerId, wantList)

    await done

  test "Should store blocks in local store":
    let pending = blocks.mapIt(engine.pendingBlocks.getWantHandle(it.cid))

    for blk in blocks:
      peerCtx.blockRequestScheduled(blk.address)

    let blocksDelivery = blocks.mapIt(BlockDelivery(blk: it, address: it.address))

    # Install NOP for want list cancellations so they don't cause a crash
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(sendWantCancellations: NopSendWantCancellationsProc)
    )

    await engine.blocksDeliveryHandler(peerId, blocksDelivery)
    let resolved = await allFinished(pending)
    check resolved.mapIt(it.read) == blocks
    for b in blocks:
      let present = await engine.localStore.hasBlock(b.cid)
      check present.tryGet()

  test "Should handle block presence":
    var handles:
      Table[Cid, Future[Block].Raising([CancelledError, RetriesExhaustedError])]

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      engine.pendingBlocks.resolve(
        blocks.filterIt(it.address in addresses).mapIt(
          BlockDelivery(blk: it, address: it.address)
        )
      )

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendWantList: sendWantList))

    # only Cids in peer want lists are requested
    handles = blocks.mapIt((it.cid, engine.pendingBlocks.getWantHandle(it.cid))).toTable

    await engine.blockPresenceHandler(
      peerId,
      blocks.mapIt(PresenceMessage.init(Presence(address: it.address, have: true))),
    )

    for a in blocks.mapIt(it.address):
      check a in peerCtx.peerHave

  test "Should send cancellations for requested blocks only":
    let
      pendingPeer = peerId # peer towards which we have pending block requests
      pendingPeerCtx = peerCtx
      senderPeer = PeerId.example # peer that will actually send the blocks
      senderPeerCtx = BlockExcPeerCtx(id: senderPeer)
      reqBlocks = @[blocks[0], blocks[4]] # blocks that we requested to pendingPeer
      reqBlockAddrs = reqBlocks.mapIt(it.address)
      blockHandles = blocks.mapIt(engine.pendingBlocks.getWantHandle(it.cid))

    var cancelled: HashSet[BlockAddress]

    engine.peers.add(senderPeerCtx)
    for address in reqBlockAddrs:
      pendingPeerCtx.blockRequestScheduled(address)

    for address in blocks.mapIt(it.address):
      senderPeerCtx.blockRequestScheduled(address)

    proc sendWantCancellations(
        id: PeerId, addresses: seq[BlockAddress]
    ) {.async: (raises: [CancelledError]).} =
      assert id == pendingPeer
      for address in addresses:
        cancelled.incl(address)

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(sendWantCancellations: sendWantCancellations)
    )

    let blocksDelivery = blocks.mapIt(BlockDelivery(blk: it, address: it.address))
    await engine.blocksDeliveryHandler(senderPeer, blocksDelivery)
    discard await allFinished(blockHandles).wait(100.millis)

    check cancelled == reqBlockAddrs.toHashSet()

asyncchecksuite "Block Download":
  var
    seckey: PrivateKey
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    advertiser: Advertiser
    peerCtx: BlockExcPeerCtx
    localStore: BlockStore
    blocks: seq[Block]

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = 1024'nb, chunkSize = 256'nb)

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    peerId = PeerId.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    localStore = CacheStore.new()
    network = BlockExcNetwork()

    discovery =
      DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)

    advertiser = Advertiser.new(localStore, blockDiscovery)

    engine = BlockExcEngine.new(
      localStore, network, discovery, advertiser, peerStore, pendingBlocks
    )

    peerCtx = BlockExcPeerCtx(id: peerId, activityTimeout: 100.milliseconds)
    engine.peers.add(peerCtx)

  test "Should reschedule blocks on peer timeout":
    let
      slowPeer = peerId
      fastPeer = PeerId.example
      slowPeerCtx = peerCtx
      # "Fast" peer has in fact a generous timeout. This should avoid timing issues
      # in the test.
      fastPeerCtx = BlockExcPeerCtx(id: fastPeer, activityTimeout: 60.seconds)
      requestedBlock = blocks[0]

    var
      slowPeerWantList = newFuture[void]("slowPeerWantList")
      fastPeerWantList = newFuture[void]("fastPeerWantList")
      slowPeerDropped = newFuture[void]("slowPeerDropped")
      slowPeerBlockRequest = newFuture[void]("slowPeerBlockRequest")
      fastPeerBlockRequest = newFuture[void]("fastPeerBlockRequest")

    engine.peers.add(fastPeerCtx)

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      check addresses == @[requestedBlock.address]

      if wantType == WantBlock:
        if id == slowPeer:
          slowPeerBlockRequest.complete()
        else:
          fastPeerBlockRequest.complete()

      if wantType == WantHave:
        if id == slowPeer:
          slowPeerWantList.complete()
        else:
          fastPeerWantList.complete()

    proc onPeerDropped(
        peer: PeerId
    ): Future[void] {.async: (raises: [CancelledError]).} =
      assert peer == slowPeer
      slowPeerDropped.complete()

    proc selectPeer(peers: seq[BlockExcPeerCtx]): BlockExcPeerCtx =
      # Looks for the slow peer.
      for peer in peers:
        if peer.id == slowPeer:
          return peer

      return peers[0]

    engine.selectPeer = selectPeer
    engine.pendingBlocks.retryInterval = 200.milliseconds
    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendWantList: sendWantList))
    engine.network.handlers.onPeerDropped = onPeerDropped

    let blockHandle = engine.requestBlock(requestedBlock.address)

    # Waits for the peer to send its want list to both peers.
    await slowPeerWantList.wait(5.seconds)
    await fastPeerWantList.wait(5.seconds)

    let blockPresence =
      @[BlockPresence(address: requestedBlock.address, type: BlockPresenceType.Have)]

    await engine.blockPresenceHandler(slowPeer, blockPresence)
    await engine.blockPresenceHandler(fastPeer, blockPresence)
    # Waits for the peer to ask for the block.
    await slowPeerBlockRequest.wait(5.seconds)
    # Don't reply and wait for the peer to be dropped by timeout.
    await slowPeerDropped.wait(5.seconds)

    # The engine should retry and ask the fast peer for the block.
    await fastPeerBlockRequest.wait(5.seconds)
    await engine.blocksDeliveryHandler(
      fastPeer, @[BlockDelivery(blk: requestedBlock, address: requestedBlock.address)]
    )

    discard await blockHandle.wait(5.seconds)

  test "Should cancel block request":
    var
      address = BlockAddress.init(blocks[0].cid)
      done = newFuture[void]()

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      done.complete()

    engine.pendingBlocks.blockRetries = 10
    engine.pendingBlocks.retryInterval = 1.seconds
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    let pending = engine.requestBlock(address)
    await done.wait(100.millis)

    pending.cancel()
    expect CancelledError:
      discard (await pending).tryGet()

asyncchecksuite "Task Handler":
  var
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    advertiser: Advertiser
    localStore: BlockStore

    peersCtx: seq[BlockExcPeerCtx]
    peers: seq[PeerId]
    blocks: seq[Block]

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256'nb)
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    peerId = PeerId.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    localStore = CacheStore.new()
    network = BlockExcNetwork()

    discovery =
      DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)

    advertiser = Advertiser.new(localStore, blockDiscovery)

    engine = BlockExcEngine.new(
      localStore, network, discovery, advertiser, peerStore, pendingBlocks
    )
    peersCtx = @[]

    for i in 0 .. 3:
      peers.add(PeerId.example)
      peersCtx.add(BlockExcPeerCtx(id: peers[i]))
      peerStore.add(peersCtx[i])

  # FIXME: this is disabled for now: I've dropped block priorities to make
  #   my life easier as I try to optimize the protocol, and also because
  #   they were not being used anywhere.
  #
  # test "Should send want-blocks in priority order":
  #   proc sendBlocksDelivery(
  #       id: PeerId, blocksDelivery: seq[BlockDelivery]
  #   ) {.async: (raises: [CancelledError]).} =
  #     check blocksDelivery.len == 2
  #     check:
  #       blocksDelivery[1].address == blocks[0].address
  #       blocksDelivery[0].address == blocks[1].address

  #   for blk in blocks:
  #     (await engine.localStore.putBlock(blk)).tryGet()
  #   engine.network.request.sendBlocksDelivery = sendBlocksDelivery

  #   # second block to send by priority
  #   peersCtx[0].peerWants.add(
  #     WantListEntry(
  #       address: blocks[0].address,
  #       priority: 49,
  #       cancel: false,
  #       wantType: WantType.WantBlock,
  #       sendDontHave: false,
  #     )
  #   )

  #   # first block to send by priority
  #   peersCtx[0].peerWants.add(
  #     WantListEntry(
  #       address: blocks[1].address,
  #       priority: 50,
  #       cancel: false,
  #       wantType: WantType.WantBlock,
  #       sendDontHave: false,
  #     )
  #   )

  #   await engine.taskHandler(peersCtx[0])

  test "Should mark outgoing blocks as sent":
    proc sendBlocksDelivery(
        id: PeerId, blocksDelivery: seq[BlockDelivery]
    ) {.async: (raises: [CancelledError]).} =
      let blockAddress = peersCtx[0].wantedBlocks.toSeq[0]
      check peersCtx[0].isBlockSent(blockAddress)

    for blk in blocks:
      (await engine.localStore.putBlock(blk)).tryGet()
    engine.network.request.sendBlocksDelivery = sendBlocksDelivery

    peersCtx[0].wantedBlocks.incl(blocks[0].address)

    await engine.taskHandler(peersCtx[0])

  test "Should not mark blocks for which local look fails as sent":
    peersCtx[0].wantedBlocks.incl(blocks[0].address)

    await engine.taskHandler(peersCtx[0])

    let blockAddress = peersCtx[0].wantedBlocks.toSeq[0]
    check not peersCtx[0].isBlockSent(blockAddress)
