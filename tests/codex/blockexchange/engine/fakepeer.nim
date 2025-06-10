import std/assertions
import std/enumerate
import std/sugar

import pkg/chronos
import pkg/libp2p

import pkg/codex/manifest
import pkg/codex/merkletree
import pkg/codex/blockexchange
import pkg/codex/blockexchange/network/network {.all.}
import pkg/codex/blockexchange/protobuf/[message, blockexc]
import pkg/codex/blocktype
import pkg/codex/rng

import ../../helpers

type
  ## Fake network in which one real peer can talk to
  ## k fake peers.
  FakeNetwork* = ref object
    fakePeers*: Table[PeerId, FakePeer]
    sender*: BlockExcNetwork

  FakePeer* = ref object
    id*: PeerId
    fakeNetwork*: FakeNetwork
    pendingRequests*: seq[BlockAddress]
    blocks*: Table[BlockAddress, Block]
    proofs*: Table[BlockAddress, CodexProof]

  Dataset* = object
    blocks*: seq[Block]
    proofs*: seq[CodexProof]
    manifest*: Manifest

proc makePeerId(): PeerId =
  let
    gen = Rng.instance()
    secKey = PrivateKey.random(gen[]).tryGet()

  return PeerId.init(secKey.getPublicKey().tryGet()).tryGet()

proc newDataset*(
    nBlocks: int = 5, blockSize: NBytes = 1024.NBytes
): Future[Dataset] {.async.} =
  let
    blocks = await makeRandomBlocks(blockSize.int * nBlocks, blockSize)
    (manifest, tree) = makeManifestAndTree(blocks).tryGet()
    treeCid = tree.rootCid.tryGet()

  return Dataset(
    blocks: blocks,
    proofs: (0 ..< blocks.len).mapIt(tree.getProof(it).tryGet()).toSeq,
    manifest: manifest,
  )

proc storeDataset*(self: FakePeer, dataset: Dataset, slice: HSlice[int, int] = 1 .. 0) =
  let actualSlice =
    if slice.len == 0:
      0 ..< dataset.blocks.len
    else:
      slice

  for index in actualSlice:
    let address = BlockAddress.init(dataset.manifest.treeCid, index.Natural)
    self.proofs[address] = dataset.proofs[index]
    self.blocks[address] = dataset.blocks[index]

proc blockPresences(self: FakePeer, addresses: seq[BlockAddress]): seq[BlockPresence] =
  collect:
    for address in addresses:
      if self.blocks.hasKey(address):
        BlockPresence(address: address, `type`: BlockPresenceType.Have)

proc getPeer(self: FakeNetwork, id: PeerId): FakePeer =
  try:
    return self.fakePeers[id]
  except KeyError as exc:
    raise newException(Defect, "peer not found")

proc newInstrumentedNetwork(self: FakeNetwork): BlockExcNetwork =
  var sender = BlockExcNetwork()

  proc sendWantList(
      id: PeerId,
      addresses: seq[BlockAddress],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.WantHave,
      full: bool = false,
      sendDontHave: bool = false,
  ) {.async: (raises: [CancelledError]).} =
    var peer = self.getPeer(id)
    case wantType
    # WantHaves are replied to immediately.
    of WantType.WantHave:
      let haves = peer.blockPresences(addresses)
      if haves.len > 0:
        await sender.handlers.onPresence(id, haves)

    # WantBlocks are deferred till `sendPendingBlocks` is called.
    of WantType.WantBlock:
      let blockAddresses = addresses.filterIt(peer.blocks.hasKey(it)).toSeq
      if blockAddresses.len > 0:
        for blockAddress in blockAddresses:
          peer.pendingRequests.add(blockAddress)

  proc sendBlocksDelivery(
      id: PeerId, blocksDelivery: seq[BlockDelivery]
  ) {.async: (raises: [CancelledError]).} =
    var peer = self.getPeer(id)
    for delivery in blocksDelivery:
      peer.blocks[delivery.address] = delivery.blk
      if delivery.proof.isSome:
        peer.proofs[delivery.address] = delivery.proof.get

  sender.request = BlockExcRequest(
    sendWantList: sendWantList,
    sendBlocksDelivery: sendBlocksDelivery,
    sendWantCancellations: proc(
        id: PeerId, addresses: seq[BlockAddress]
    ) {.async: (raises: [CancelledError]).} =
      discard,
  )

  return sender

proc sendPendingBlocks*(self: FakePeer) {.async.} =
  ## Replies to any pending block requests.
  let blocks = collect:
    for blockAddress in self.pendingRequests:
      if not self.blocks.hasKey(blockAddress):
        continue

      let proof =
        if blockAddress in self.proofs:
          self.proofs[blockAddress].some
        else:
          CodexProof.none

      BlockDelivery(address: blockAddress, blk: self.blocks[blockAddress], proof: proof)

  await self.fakeNetwork.sender.handlers.onBlocksDelivery(self.id, blocks)

proc newPeer*(self: FakeNetwork): FakePeer =
  ## Adds a new `FakePeer` to a `FakeNetwork`.
  let peer = FakePeer(id: makePeerId(), fakeNetwork: self)
  self.fakePeers[peer.id] = peer
  return peer

proc new*(_: type FakeNetwork): FakeNetwork =
  let fakeNetwork = FakeNetwork()
  fakeNetwork.sender = fakeNetwork.newInstrumentedNetwork()
  return fakeNetwork
