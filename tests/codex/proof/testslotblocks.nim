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

  test "Can get index for slot block":
    proc getIndex(i: int): uint64 =
      getIndexForSlotBlock(slot, bytesPerBlock.NBytes, i)

    proc getExpected(i: int): uint64 =
      (slotIndex * numberOfSlotBlocks + i).uint64

    check:
      getIndex(0) == getExpected(0)
      getIndex(0) == 12
      getIndex(1) == getExpected(1)
      getIndex(1) == 13
      getIndex(10) == getExpected(10)
      getIndex(10) == 22

  test "Can get slot block by index":
    proc getBlocks(i: int): Future[(bt.Block, bt.Block)] {.async.} =
      let
        slotBlock = (await getSlotBlock(slot, localStore, 3)).tryget()
        expectedIndex = getIndexForSlotBlock(slot, bytesPerBlock.NBytes, 3)
        expectedBlock = datasetBlocks[expectedIndex]
      return (slotBlock, expectedBlock)

    let (slotBlock0, expectedBlock0) = await getBlocks(0)
    let (slotBlock3, expectedBlock3) = await getBlocks(3)
    let (slotBlockLast5, expectedBlockLast5) = await getBlocks(numberOfSlotBlocks - 3)
    let (slotBlockLast, expectedBlockLast) = await getBlocks(numberOfSlotBlocks - 1)

    check:
      slotBlock0.cid == expectedBlock0.cid
      slotBlock0.data == expectedBlock0.data
      slotBlock3.cid == expectedBlock3.cid
      slotBlock3.data == expectedBlock3.data
      slotBlockLast5.cid == expectedBlockLast5.cid
      slotBlockLast5.data == expectedBlockLast5.data
      slotBlockLast.cid == expectedBlockLast.cid
      slotBlockLast.data == expectedBlockLast.data

  test "Can fail to get block when index is out of range":
    let
      b1 = await getSlotBlock(slot, localStore, numberOfSlotBlocks)
      b2 = await getSlotBlock(slot, localStore, numberOfSlotBlocks + 1)

    check:
      b1.isErr
      b2.isErr
