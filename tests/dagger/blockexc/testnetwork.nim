import std/sequtils
import std/tables

import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors
import questionable
import questionable/results
import pkg/protobuf_serialization

import pkg/dagger/rng
import pkg/dagger/chunker
import pkg/dagger/blocktype as bt
import pkg/dagger/blockexchange

import ../helpers
import ../examples

suite "NetworkStore network":
  let
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).get()
    peerId = PeerID.init(seckey.getPublicKey().get()).get()
    chunker = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)

  var
    network: BlockExcNetwork
    networkPeer: NetworkPeer
    buffer: BufferStream
    blocks: seq[bt.Block]
    done: Future[void]

  proc getConn(): Future[Connection] {.async.} =
    return Connection(buffer)

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.init(chunk).get())

    done = newFuture[void]()
    buffer = BufferStream.new()
    network = BlockExcNetwork.new(
      switch = newStandardSwitch(),
      connProvider = getConn)
    network.setupPeer(peerId)
    networkPeer = network.peers[peerId]
    discard await networkPeer.connect()

  test "Want List handler":
    proc wantListHandler(peer: PeerID, wantList: WantList) {.gcsafe, async.} =
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
    proc blocksHandler(peer: PeerID, blks: seq[bt.Block]) {.gcsafe, async.} =
      check blks == blocks
      done.complete()

    network.handlers.onBlocks = blocksHandler

    let msg = Message(payload: makeBlocks(blocks))
    await buffer.pushData(lenPrefix(Protobuf.encode(msg)))

    await done.wait(500.millis)

  test "Presence Handler":
    proc presenceHandler(
      peer: PeerID,
      precense: seq[BlockPresence]) {.gcsafe, async.} =
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

  test "handles account messages":
    let account = Account(address: EthAddress.example)

    proc handleAccount(peer: PeerID, received: Account) {.gcsafe, async.} =
      check received == account
      done.complete()

    network.handlers.onAccount = handleAccount

    let message = Message(account: AccountMessage.init(account))
    await buffer.pushData(lenPrefix(Protobuf.encode(message)))

    await done.wait(100.millis)

  test "handles payment messages":
    let payment = SignedState.example

    proc handlePayment(peer: PeerID, received: SignedState) {.gcsafe, async.} =
      check received == payment
      done.complete()

    network.handlers.onPayment = handlePayment

    let message = Message(payment: StateChannelUpdate.init(payment))
    await buffer.pushData(lenPrefix(Protobuf.encode(message)))

    await done.wait(100.millis)

suite "NetworkStore Network - e2e":
  let
    chunker = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)

  var
    switch1, switch2: Switch
    network1, network2: BlockExcNetwork
    blocks: seq[bt.Block]
    done: Future[void]

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.init(chunk).get())

    done = newFuture[void]()
    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()
    await switch1.start()
    await switch2.start()

    network1 = BlockExcNetwork.new(
      switch = switch1)
    switch1.mount(network1)

    network2 = BlockExcNetwork.new(
      switch = switch2)
    switch2.mount(network2)

    await switch1.connect(
      switch2.peerInfo.peerId,
      switch2.peerInfo.addrs)

  teardown:
    await allFuturesThrowing(
      switch1.stop(),
      switch2.stop())

  test "broadcast want list":
    proc wantListHandler(peer: PeerID, wantList: WantList) {.gcsafe, async.} =
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
    proc blocksHandler(peer: PeerID, blks: seq[bt.Block]) {.gcsafe, async.} =
      check blks == blocks
      done.complete()

    network2.handlers.onBlocks = blocksHandler
    network1.broadcastBlocks(
      switch2.peerInfo.peerId,
      blocks)

    await done.wait(500.millis)

  test "broadcast precense":
    proc presenceHandler(
      peer: PeerID,
      precense: seq[BlockPresence]) {.gcsafe, async.} =
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

  test "broadcasts account":
    let account = Account(address: EthAddress.example)

    proc handleAccount(peer: PeerID, received: Account) {.gcsafe, async.} =
      check received == account
      done.complete()

    network2.handlers.onAccount = handleAccount

    network1.broadcastAccount(switch2.peerInfo.peerId, account)

    await done.wait(500.millis)

  test "broadcasts payment":
    let payment = SignedState.example

    proc handlePayment(peer: PeerID, received: SignedState) {.gcsafe, async.} =
      check received == payment
      done.complete()

    network2.handlers.onPayment = handlePayment

    network1.broadcastPayment(switch2.peerInfo.peerId, payment)

    await done.wait(500.millis)
