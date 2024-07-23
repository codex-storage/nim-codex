import std/sequtils
import std/random

import pkg/chronos
import pkg/libp2p/routing_record
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/blockexchange
import pkg/codex/stores
import pkg/codex/chunker
import pkg/codex/discovery
import pkg/codex/blocktype as bt
import pkg/codex/manifest

import ../../../asynctest
import ../../helpers
import ../../helpers/mockdiscovery
import ../../examples

asyncchecksuite "Advertiser":
  var
    blockDiscovery: MockDiscovery
    localStore: BlockStore
    advertiser: Advertiser
  let
    manifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 123.NBytes,
      datasetSize = 234.NBytes)
    manifestBlk = Block.new(data = manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  setup:
    blockDiscovery = MockDiscovery.new()
    localStore = CacheStore.new()

    advertiser = Advertiser.new(
      localStore,
      blockDiscovery
    )

    await advertiser.start()

  teardown:
    await advertiser.stop()

  test "blockStored should queue manifest Cid for advertising":
    (await localStore.putBlock(manifestBlk)).tryGet()

    check:
      manifestBlk.cid in advertiser.advertiseQueue

  test "blockStored should queue tree Cid for advertising":
    (await localStore.putBlock(manifestBlk)).tryGet()

    check:
      manifest.treeCid in advertiser.advertiseQueue

  test "blockStored should not queue non-manifest non-tree CIDs for discovery":
    let blk = bt.Block.example
      
    (await localStore.putBlock(blk)).tryGet()

    check:
      blk.cid notin advertiser.advertiseQueue

  test "Should not queue if there is already an inflight advertise request":
    var
      reqs = newFuture[void]()
      count = 0

    blockDiscovery.publishBlockProvideHandler =
      proc(d: MockDiscovery, cid: Cid) {.async, gcsafe.} =
        check cid == manifestBlk.cid
        if count > 0:
          check false
        count.inc

        await reqs # queue the request

    (await localStore.putBlock(manifestBlk)).tryGet()
    (await localStore.putBlock(manifestBlk)).tryGet()

    reqs.complete()




#   test "Should schedule block requests":
#     let
#       wantList = makeWantList(
#         blocks.mapIt( it.cid ),
#         wantType = WantType.WantBlock) # only `wantBlock` are stored in `peerWants`

#     proc handler() {.async.} =
#       let ctx = await engine.taskQueue.pop()
#       check ctx.id == peerId
#       # only `wantBlock` scheduled
#       check ctx.peerWants.mapIt( it.address.cidOrTreeCid ) == blocks.mapIt( it.cid )

#     let done = handler()
#     await engine.wantListHandler(peerId, wantList)
#     await done

#   test "Should handle want list":
#     let
#       done = newFuture[void]()
#       wantList = makeWantList(blocks.mapIt( it.cid ))

#     proc sendPresence(peerId: PeerId, presence: seq[BlockPresence]) {.gcsafe, async.} =
#       check presence.mapIt( it.address ) == wantList.entries.mapIt( it.address )
#       done.complete()

#     engine.network = BlockExcNetwork(
#       request: BlockExcRequest(
#         sendPresence: sendPresence
#     ))

#     await allFuturesThrowing(
#       allFinished(blocks.mapIt( localStore.putBlock(it) )))

#     await engine.wantListHandler(peerId, wantList)
#     await done

#   test "Should handle want list - `dont-have`":
#     let
#       done = newFuture[void]()
#       wantList = makeWantList(
#         blocks.mapIt( it.cid ),
#         sendDontHave = true)

#     proc sendPresence(peerId: PeerId, presence: seq[BlockPresence]) {.gcsafe, async.} =
#       check presence.mapIt( it.address ) == wantList.entries.mapIt( it.address )
#       for p in presence:
#         check:
#           p.`type` == BlockPresenceType.DontHave

#       done.complete()

#     engine.network = BlockExcNetwork(request: BlockExcRequest(
#       sendPresence: sendPresence
#     ))

#     await engine.wantListHandler(peerId, wantList)
#     await done

#   test "Should handle want list - `dont-have` some blocks":
#     let
#       done = newFuture[void]()
#       wantList = makeWantList(
#         blocks.mapIt( it.cid ),
#         sendDontHave = true)

#     proc sendPresence(peerId: PeerId, presence: seq[BlockPresence]) {.gcsafe, async.} =
#       for p in presence:
#         if p.address.cidOrTreeCid != blocks[0].cid and p.address.cidOrTreeCid != blocks[1].cid:
#           check p.`type` == BlockPresenceType.DontHave
#         else:
#           check p.`type` == BlockPresenceType.Have

#       done.complete()

#     engine.network = BlockExcNetwork(
#       request: BlockExcRequest(
#         sendPresence: sendPresence
#     ))

#     (await engine.localStore.putBlock(blocks[0])).tryGet()
#     (await engine.localStore.putBlock(blocks[1])).tryGet()
#     await engine.wantListHandler(peerId, wantList)

#     await done

#   test "Should store blocks in local store":
#     let pending = blocks.mapIt(
#       engine.pendingBlocks.getWantHandle( it.cid )
#     )

#     let blocksDelivery = blocks.mapIt(BlockDelivery(blk: it, address: it.address))

#     # Install NOP for want list cancellations so they don't cause a crash
#     engine.network = BlockExcNetwork(
#       request: BlockExcRequest(sendWantCancellations: NopSendWantCancellationsProc))

#     await engine.blocksDeliveryHandler(peerId, blocksDelivery)
#     let resolved = await allFinished(pending)
#     check resolved.mapIt( it.read ) == blocks
#     for b in blocks:
#       let present = await engine.localStore.hasBlock(b.cid)
#       check present.tryGet()

#   test "Should send payments for received blocks":
#     let
#       done = newFuture[void]()
#       account = Account(address: EthAddress.example)
#       peerContext = peerStore.get(peerId)

#     peerContext.account = account.some
#     peerContext.blocks = blocks.mapIt(
#       (it.address, Presence(address: it.address, price: rand(uint16).u256))
#     ).toTable

#     engine.network = BlockExcNetwork(
#       request: BlockExcRequest(
#         sendPayment: proc(receiver: PeerId, payment: SignedState) {.gcsafe, async.} =
#           let
#             amount =
#               blocks.mapIt(
#                 peerContext.blocks[it.address].price
#               ).foldl(a + b)

#             balances = !payment.state.outcome.balances(Asset)

#           check receiver == peerId
#           check balances[account.address.toDestination] == amount
#           done.complete(),

#         # Install NOP for want list cancellations so they don't cause a crash
#         sendWantCancellations: NopSendWantCancellationsProc
#     ))

#     await engine.blocksDeliveryHandler(peerId, blocks.mapIt(
#       BlockDelivery(blk: it, address: it.address)))
#     await done.wait(100.millis)

#   test "Should handle block presence":
#     var
#       handles: Table[Cid, Future[Block]]

#     proc sendWantList(
#       id: PeerId,
#       addresses: seq[BlockAddress],
#       priority: int32 = 0,
#       cancel: bool = false,
#       wantType: WantType = WantType.WantHave,
#       full: bool = false,
#       sendDontHave: bool = false) {.gcsafe, async.} =
#         engine.pendingBlocks.resolve(blocks
#         .filterIt( it.address in addresses )
#         .mapIt(BlockDelivery(blk: it, address: it.address)))

#     engine.network = BlockExcNetwork(
#       request: BlockExcRequest(
#         sendWantList: sendWantList
#     ))

#     # only Cids in peer want lists are requested
#     handles = blocks.mapIt(
#       (it.cid, engine.pendingBlocks.getWantHandle( it.cid ))).toTable

#     let price = UInt256.example
#     await engine.blockPresenceHandler(
#       peerId,
#       blocks.mapIt(
#         PresenceMessage.init(
#           Presence(
#             address: it.address,
#             have: true,
#             price: price
#       ))))

#     for a in blocks.mapIt(it.address):
#       check a in peerCtx.peerHave
#       check peerCtx.blocks[a].price == price

#   test "Should send cancellations for received blocks":
#     let
#       pending = blocks.mapIt(engine.pendingBlocks.getWantHandle(it.cid))
#       blocksDelivery = blocks.mapIt(BlockDelivery(blk: it, address: it.address))
#       cancellations = newTable(
#         blocks.mapIt((it.address, newFuture[void]())).toSeq
#       )

#     proc sendWantCancellations(
#       id: PeerId,
#       addresses: seq[BlockAddress]
#     ) {.gcsafe, async.} =
#         for address in addresses:
#           cancellations[address].complete()

#     engine.network = BlockExcNetwork(
#       request: BlockExcRequest(
#         sendWantCancellations: sendWantCancellations
#     ))

#     await engine.blocksDeliveryHandler(peerId, blocksDelivery)
#     discard await allFinished(pending)
#     await allFuturesThrowing(cancellations.values().toSeq)
