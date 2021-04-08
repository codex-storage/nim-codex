import std/sequtils
import std/tables

import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors
import pkg/protobuf_serialization

import pkg/dagger/stores/memorystore
import pkg/dagger/bitswap/network
import pkg/dagger/bitswap/protobuf/payments
import pkg/dagger/p2p/rng
import pkg/dagger/chunker
import pkg/dagger/blocktype as bt

import ../helpers
import ../examples

suite "Bitswap network":
  let
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerID.init(seckey.getKey().tryGet()).tryGet()
    chunker = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks = chunker.mapIt( bt.Block.new(it) )

  var
    network: BitswapNetwork
    networkPeer: NetworkPeer
    buffer: BufferStream
    done: Future[void]

  proc getConn(): Future[Connection] {.async.} =
    return Connection(buffer)

  setup:
    done = newFuture[void]()
    buffer = newBufferStream()
    network = BitswapNetwork.new(
      switch = newStandardSwitch(),
      wallet = Wallet.init(EthPrivateKey.random()),
      connProvider = getConn)
    network.setupPeer(peerId)
    networkPeer = network.peers[peerId]
    discard await networkPeer.connect()

  test "Want List handler":
    proc wantListHandler(peer: PeerID, wantList: WantList) {.gcsafe.} =
      # check that we got the correct amount of entries
      check wantList.entries.len == 4

      for b in blocks:
        check b.cid in wantList.entries
        let entry = wantList.entries[wantList.entries.find(b.cid)]
        check entry.wantType == WantType.wantHave
        check entry.priority == 1
        check entry.cancel == true
        check entry.sendDontHave == true

      done.complete()

    network.handlers.onWantList = wantListHandler

    let wantList = makeWantList(
      blocks.mapIt( it.cid ),
      1, true, WantType.wantHave,
      true, true)

    let msg = Message(wantlist: wantList)
    await buffer.pushData(lenPrefix(Protobuf.encode(msg)))

    await done.wait(500.millis)

  test "Blocks Handler":
    proc blocksHandler(peer: PeerID, blks: seq[bt.Block]) {.gcsafe.} =
      check blks == blocks
      done.complete()

    network.handlers.onBlocks = blocksHandler

    let msg = Message(payload: makeBlocks(blocks))
    await buffer.pushData(lenPrefix(Protobuf.encode(msg)))

    await done.wait(500.millis)

  test "Presence Handler":
    proc presenceHandler(peer: PeerID, precense: seq[BlockPresence]) {.gcsafe.} =
      for b in blocks:
        check:
          b.cid in precense

      done.complete()

    network.handlers.onPresence = presenceHandler

    let msg = Message(
      blockPresences: blocks.mapIt(
        BlockPresence(
          cid: it.cid.data.buffer,
          type: BlockPresenceType.presenceHave
      )))
    await buffer.pushData(lenPrefix(Protobuf.encode(msg)))

    await done.wait(500.millis)

  test "handles pricing messages":
    let pricing = Pricing.example

    proc handlePricing(peer: PeerID, received: Pricing) =
      check received == pricing
      done.complete()

    network.handlers.onPricing = handlePricing

    let message = Message(pricing: PricingMessage.init(pricing))
    await buffer.pushData(lenPrefix(Protobuf.encode(message)))

    await done.wait(100.millis)

suite "Bitswap Network - e2e":
  let
    chunker = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks = chunker.mapIt( bt.Block.new(it) )

  var
    switch1, switch2: Switch
    wallet1, wallet2: Wallet
    network1, network2: BitswapNetwork
    awaiters: seq[Future[void]]
    done: Future[void]

  setup:
    done = newFuture[void]()
    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()
    wallet1 = Wallet.init(EthPrivateKey.random())
    wallet2 = Wallet.init(EthPrivateKey.random())
    awaiters.add(await switch1.start())
    awaiters.add(await switch2.start())

    network1 = BitswapNetwork.new(switch1, wallet1)
    switch1.mount(network1)

    network2 = BitswapNetwork.new(switch2, wallet2)
    switch2.mount(network2)

    await switch1.connect(
      switch2.peerInfo.peerId,
      switch2.peerInfo.addrs)

  teardown:
    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())

    await allFuturesThrowing(awaiters)

  test "broadcast want list":
    proc wantListHandler(peer: PeerID, wantList: WantList) {.gcsafe.} =
      # check that we got the correct amount of entries
      check wantList.entries.len == 4

      for b in blocks:
        check b.cid in wantList.entries
        let entry = wantList.entries[wantList.entries.find(b.cid)]
        check entry.wantType == WantType.wantHave
        check entry.priority == 1
        check entry.cancel == true
        check entry.sendDontHave == true

      done.complete()

    network2.handlers.onWantList = wantListHandler
    network1.broadcastWantList(
      switch2.peerInfo.peerId,
      blocks.mapIt( it.cid ),
      1, true, WantType.wantHave,
      true, true)

    await done.wait(500.millis)

  test "broadcast blocks":
    proc blocksHandler(peer: PeerID, blks: seq[bt.Block]) {.gcsafe.} =
      check blks == blocks
      done.complete()

    network2.handlers.onBlocks = blocksHandler
    network1.broadcastBlocks(
      switch2.peerInfo.peerId,
      blocks)

    await done.wait(500.millis)

  test "broadcast precense":
    proc presenceHandler(peer: PeerID, precense: seq[BlockPresence]) {.gcsafe.} =
      for b in blocks:
        check:
          b.cid in precense

      done.complete()

    network2.handlers.onPresence = presenceHandler

    network1.broadcastBlockPresence(
      switch2.peerInfo.peerId,
      blocks.mapIt(
        BlockPresence(
          cid: it.cid.data.buffer,
          type: BlockPresenceType.presenceHave
      )))

    await done.wait(500.millis)
