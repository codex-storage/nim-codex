import std/sequtils

import pkg/chronos
import pkg/asynctest
import pkg/codex/rng
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree

import pkg/codex/proof/slotblocks
import pkg/codex/proof/indexing

import ../helpers
import ../examples

let
  bytesPerBlock = 64 * 1024
  numberOfSlotBlocks = 4
  slotIndex = 3

asyncchecksuite "Test slotblocks - manifest":
  let
    localStore = CacheStore.new()
    manifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 100.MiBs)

  var
    manifestBlock = bt.Block.new(manifest.encode().tryGet(), codec = DagPBCodec).tryGet()
    slot = Slot(
      request: StorageRequest(
        ask: StorageAsk(
          slotSize: u256(bytesPerBlock * numberOfSlotBlocks)
        ),
        content: StorageContent(
          cid: $manifestBlock.cid
        ),
      ),
      slotIndex: u256(slotIndex)
    )

  setup:
    discard await localStore.putBlock(manifestBlock)

  test "Can get manifest for slot":
    let m = (await getManifestForSlot(slot, localStore)).tryGet()

    check:
      m.treeCid == manifest.treeCid

  test "Can fail to get manifest for invalid cid":
    slot.request.content.cid = "invalid"
    let m = (await getManifestForSlot(slot, localStore))

    check:
      m.isErr

  test "Can fail to get manifest when manifest block not found":
    let
      emptyStore = CacheStore.new()
      m = (await getManifestForSlot(slot, emptyStore))

    check:
      m.isErr

  test "Can fail to get manifest when manifest fails to decode":
    manifestBlock.data = @[]

    let m = (await getManifestForSlot(slot, localStore))

    check:
      m.isErr


asyncchecksuite "Test slotblocks - slot blocks by index":
  let
    totalNumberOfSlots = 4
    localStore = CacheStore.new()
    chunker = RandomChunker.new(rng.Rng.instance(),
      size = bytesPerBlock * numberOfSlotBlocks * totalNumberOfSlots,
      chunkSize = bytesPerBlock)

  var
    manifest: Manifest
    manifestBlock: bt.Block
    slot: Slot
    datasetBlocks: seq[bt.Block]

  proc createDatasetBlocks(): Future[void] {.async.} =
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break
      let b = bt.Block.new(chunk).tryGet()
      datasetBlocks.add(b)
      discard await localStore.putBlock(b)

  proc createManifest(): Future[void] {.async.} =
    let
      cids = datasetBlocks.mapIt(it.cid)
      tree = MerkleTree.init(cids).tryGet()
      treeCid = tree.rootCid().tryGet()

    for index, cid in cids:
      let proof = tree.getProof(index).tryget()
      discard await localStore.putBlockCidAndProof(treeCid, index, cid, proof)

    manifest = Manifest.new(
      treeCid = treeCid,
      blockSize = bytesPerBlock.NBytes,
      datasetSize = (bytesPerBlock * numberOfSlotBlocks * totalNumberOfSlots).NBytes)
    manifestBlock = bt.Block.new(manifest.encode().tryGet(), codec = DagPBCodec).tryGet()


  proc createSlot(): void =
    slot = Slot(
      request: StorageRequest(
        ask: StorageAsk(
          slotSize: u256(bytesPerBlock * numberOfSlotBlocks)
        ),
        content: StorageContent(
          cid: $manifestBlock.cid
        ),
      ),
      slotIndex: u256(slotIndex)
    )

  setup:
    await createDatasetBlocks()
    await createManifest()
    createSlot()
    discard await localStore.putBlock(manifestBlock)

  for input in [0, 1, numberOfSlotBlocks-1]:
    test "Can get slot block by index (" & $input & ")":
      let
        slotBlock = (await getSlotBlock(slot, localStore, input.uint64)).tryget()
        expectedDatasetBlockIndex = getDatasetBlockIndexForSlotBlockIndex(slot, bytesPerBlock.uint64, input.uint64)
        expectedBlock = datasetBlocks[expectedDatasetBlockIndex]

      check:
        slotBlock.cid == expectedBlock.cid
        slotBlock.data == expectedBlock.data

  test "Can fail to get block when index is out of range":
    let
      b1 = await getSlotBlock(slot, localStore, numberOfSlotBlocks.uint64)
      b2 = await getSlotBlock(slot, localStore, (numberOfSlotBlocks + 1).uint64)

    check:
      b1.isErr
      b2.isErr
