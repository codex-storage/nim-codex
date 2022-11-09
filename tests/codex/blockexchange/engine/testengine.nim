import std/sequtils
import std/random
import std/algorithm

import pkg/stew/byteutils
import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/libp2pdht/discv5/protocol as discv5

import pkg/codex/rng
import pkg/codex/blockexchange
import pkg/codex/stores
import pkg/codex/chunker
import pkg/codex/discovery
import pkg/codex/blocktype as bt
import pkg/codex/utils/asyncheapqueue

import ../../helpers
import ../../examples

suite "NetworkStore engine basic":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerID
    chunker: Chunker
    wallet: WalletRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    blocks: seq[bt.Block]
    done: Future[void]

  setup:
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerID.init(seckey.getPublicKey().tryGet()).tryGet()
    chunker = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)
    wallet = WalletRef.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    done = newFuture[void]()

  test "Should send want list to new peers":
    proc sendWantList(
      id: PeerID,
      cids: seq[Cid],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.wantHave,
      full: bool = false,
      sendDontHave: bool = false) {.gcsafe, async.} =
        check cids.mapIt($it).sorted == blocks.mapIt( $it.cid ).sorted
        done.complete()

    let
      network = BlockExcNetwork(request: BlockExcRequest(
        sendWantList: sendWantList,
      ))

      localStore = CacheStore.new(blocks.mapIt( it ))
      discovery = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks)

      engine = BlockExcEngine.new(
        localStore,
        wallet,
        network,
        discovery,
        peerStore,
        pendingBlocks)

    for b in blocks:
      discard engine.pendingBlocks.getWantHandle(b.cid)
    await engine.setupPeer(peerId)

    await done.wait(100.millis)

  test "Should send account to new peers":
    let pricing = Pricing.example

    proc sendAccount(peer: PeerID, account: Account) {.gcsafe, async.} =
      check account.address == pricing.address
      done.complete()

    let
      network = BlockExcNetwork(
        request: BlockExcRequest(
          sendAccount: sendAccount
      ))

      localStore = CacheStore.new()
      discovery = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks)

      engine = BlockExcEngine.new(
        localStore,
        wallet,
        network,
        discovery,
        peerStore,
        pendingBlocks)

    engine.pricing = pricing.some
    await engine.setupPeer(peerId)

    await done.wait(100.millis)

suite "NetworkStore engine handlers":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerID
    chunker: Chunker
    wallet: WalletRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    peerCtx: BlockExcPeerCtx
    localStore: BlockStore
    done: Future[void]
    blocks: seq[bt.Block]

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = 1024, chunkSize = 256)

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerID.init(seckey.getPublicKey().tryGet()).tryGet()
    wallet = WalletRef.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    localStore = CacheStore.new()
    network = BlockExcNetwork()

    discovery = DiscoveryEngine.new(
      localStore,
      peerStore,
      network,
      blockDiscovery,
      pendingBlocks)

    engine = BlockExcEngine.new(
      localStore,
      wallet,
      network,
      discovery,
      peerStore,
      pendingBlocks)

    peerCtx = BlockExcPeerCtx(
      id: peerId
    )
    engine.peers.add(peerCtx)

  test "Should schedule block requests":
    let
      wantList = makeWantList(
        blocks.mapIt( it.cid ),
        wantType = WantType.wantBlock) # only `wantBlock` are stored in `peerWants`

    proc handler() {.async.} =
      let ctx = await engine.taskQueue.pop()
      check ctx.id == peerId
      # only `wantBlock` scheduled
      check ctx.peerWants.mapIt( it.cid ) == blocks.mapIt( it.cid )

    let done = handler()
    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list":
    let
      done = newFuture[void]()
      wantList = makeWantList(blocks.mapIt( it.cid ))

    proc sendPresence(peerId: PeerID, presence: seq[BlockPresence]) {.gcsafe, async.} =
      check presence.mapIt( it.cid ) == wantList.entries.mapIt( it.`block` )
      done.complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendPresence: sendPresence
    ))

    await allFuturesThrowing(
      allFinished(blocks.mapIt( localStore.putBlock(it) )))

    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list - `dont-have`":
    let
      done = newFuture[void]()
      wantList = makeWantList(
        blocks.mapIt( it.cid ),
        sendDontHave = true)

    proc sendPresence(peerId: PeerID, presence: seq[BlockPresence]) {.gcsafe, async.} =
      check presence.mapIt( it.cid ) == wantList.entries.mapIt( it.`block` )
      for p in presence:
        check:
          p.`type` == BlockPresenceType.presenceDontHave

      done.complete()

    engine.network = BlockExcNetwork(request: BlockExcRequest(
      sendPresence: sendPresence
    ))

    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list - `dont-have` some blocks":
    let
      done = newFuture[void]()
      wantList = makeWantList(
        blocks.mapIt( it.cid ),
        sendDontHave = true)

    proc sendPresence(peerId: PeerID, presence: seq[BlockPresence]) {.gcsafe, async.} =
      let
        cid1Buf = blocks[0].cid.data.buffer
        cid2Buf = blocks[1].cid.data.buffer

      for p in presence:
        if p.cid != cid1Buf and p.cid != cid2Buf:
          check p.`type` == BlockPresenceType.presenceDontHave
        else:
          check p.`type` == BlockPresenceType.presenceHave

      done.complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendPresence: sendPresence
    ))

    (await engine.localStore.putBlock(blocks[0])).tryGet()
    (await engine.localStore.putBlock(blocks[1])).tryGet()
    await engine.wantListHandler(peerId, wantList)

    await done

  test "Should store blocks in local store":
    let pending = blocks.mapIt(
      engine.pendingBlocks.getWantHandle( it.cid )
    )

    await engine.blocksHandler(peerId, blocks)
    let resolved = await allFinished(pending)
    check resolved.mapIt( it.read ) == blocks
    for b in blocks:
      let present = await engine.localStore.hasBlock(b.cid)
      check present.tryGet()

  test "Should send payments for received blocks":
    let
      done = newFuture[void]()
      account = Account(address: EthAddress.example)
      peerContext = peerStore.get(peerId)

    peerContext.account = account.some
    peerContext.blocks = blocks.mapIt(
      (it.cid, Presence(cid: it.cid, price: rand(uint16).u256))
    ).toTable

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendPayment: proc(receiver: PeerID, payment: SignedState) {.gcsafe, async.} =
          let
            amount =
              blocks.mapIt(
                peerContext.blocks[it.cid].price
              ).foldl(a + b)

            balances = !payment.state.outcome.balances(Asset)

          check receiver == peerId
          check balances[account.address.toDestination] == amount
          done.complete()
    ))

    await engine.blocksHandler(peerId, blocks)
    await done.wait(100.millis)

  test "Should handle block presence":
    var
      handles: Table[Cid, Future[bt.Block]]

    proc sendWantList(
      id: PeerID,
      cids: seq[Cid],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.wantHave,
      full: bool = false,
      sendDontHave: bool = false) {.gcsafe, async.} =
        engine.pendingBlocks.resolve(blocks.filterIt( it.cid in cids ))

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList
    ))

    # only Cids in peer want lists are requested
    handles = blocks.mapIt(
      (it.cid, engine.pendingBlocks.getWantHandle( it.cid ))).toTable

    let price = UInt256.example
    await engine.blockPresenceHandler(
      peerId,
      blocks.mapIt(
        PresenceMessage.init(
          Presence(
            cid: it.cid,
            have: true,
            price: price
      ))))

    for cid in blocks.mapIt(it.cid):
      check cid in peerCtx.peerHave
      check peerCtx.blocks[cid].price == price

suite "Task Handler":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerID
    chunker: Chunker
    wallet: WalletRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    peerCtx: BlockExcPeerCtx
    localStore: BlockStore

    peersCtx: seq[BlockExcPeerCtx]
    peers: seq[PeerID]
    blocks: seq[bt.Block]

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = 1024, chunkSize = 256)
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerID.init(seckey.getPublicKey().tryGet()).tryGet()
    wallet = WalletRef.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    localStore = CacheStore.new()
    network = BlockExcNetwork()

    discovery = DiscoveryEngine.new(
      localStore,
      peerStore,
      network,
      blockDiscovery,
      pendingBlocks)

    engine = BlockExcEngine.new(
      localStore,
      wallet,
      network,
      discovery,
      peerStore,
      pendingBlocks)
    peersCtx = @[]

    for i in 0..3:
      let seckey = PrivateKey.random(rng[]).tryGet()
      peers.add(PeerID.init(seckey.getPublicKey().tryGet()).tryGet())

      peersCtx.add(BlockExcPeerCtx(
        id: peers[i]
      ))
      peerStore.add(peersCtx[i])

    engine.pricing = Pricing.example.some

  test "Should send want-blocks in priority order":
    proc sendBlocks(
      id: PeerID,
      blks: seq[bt.Block]) {.gcsafe, async.} =
      check blks.len == 2
      check:
        blks[1].cid == blocks[0].cid
        blks[0].cid == blocks[1].cid

    for blk in blocks:
      (await engine.localStore.putBlock(blk)).tryGet()
    engine.network.request.sendBlocks = sendBlocks

    # second block to send by priority
    peersCtx[0].peerWants.add(
      Entry(
        `block`: blocks[0].cid.data.buffer,
        priority: 49,
        cancel: false,
        wantType: WantType.wantBlock,
        sendDontHave: false)
    )

    # first block to send by priority
    peersCtx[0].peerWants.add(
      Entry(
        `block`: blocks[1].cid.data.buffer,
        priority: 50,
        cancel: false,
        wantType: WantType.wantBlock,
        sendDontHave: false)
    )

    await engine.taskHandler(peersCtx[0])

  test "Should send presence":
    let present = blocks
    let missing = @[bt.Block.new("missing".toBytes).tryGet()]
    let price = (!engine.pricing).price

    proc sendPresence(id: PeerID, presence: seq[BlockPresence]) {.gcsafe, async.} =
      check presence.mapIt(!Presence.init(it)) == @[
        Presence(cid: present[0].cid, have: true, price: price),
        Presence(cid: present[1].cid, have: true, price: price),
        Presence(cid: missing[0].cid, have: false)
      ]

    for blk in blocks:
      (await engine.localStore.putBlock(blk)).tryGet()
    engine.network.request.sendPresence = sendPresence

    # have block
    peersCtx[0].peerWants.add(
      Entry(
        `block`: present[0].cid.data.buffer,
        priority: 1,
        cancel: false,
        wantType: WantType.wantHave,
        sendDontHave: false)
    )

    # have block
    peersCtx[0].peerWants.add(
      Entry(
        `block`: present[1].cid.data.buffer,
        priority: 1,
        cancel: false,
        wantType: WantType.wantHave,
        sendDontHave: false)
    )

    # don't have block
    peersCtx[0].peerWants.add(
      Entry(
        `block`: missing[0].cid.data.buffer,
        priority: 1,
        cancel: false,
        wantType: WantType.wantHave,
        sendDontHave: false)
    )

    await engine.taskHandler(peersCtx[0])
