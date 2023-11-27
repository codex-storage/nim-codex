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
  datasetSlotIndex = 3

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
      slotIndex: u256(datasetSlotIndex)
    )

  setup:
    discard await localStore.putBlock(manifestBlock)

  proc getManifest(store: BlockStore): Future[?!Manifest] {.async.} =
    without slotBlocks =? await SlotBlocks.new(slot, store), err:
      return failure(err)
    return success(slotBlocks.manifest)

  test "Can get manifest for slot":
    let m = (await getManifest(localStore)).tryGet()

    check:
      m.treeCid == manifest.treeCid

  test "Can fail to get manifest for invalid cid":
    slot.request.content.cid = "invalid"
    let m = (await getManifest(localStore))

    check:
      m.isErr

  test "Can fail to get manifest when manifest block not found":
    let
      emptyStore = CacheStore.new()
      m = (await getManifest(emptyStore))

    check:
      m.isErr

  test "Can fail to get manifest when manifest fails to decode":
    manifestBlock.data = @[]

    let m = (await getManifest(localStore))

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
    slotBlocks: SlotBlocks

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
      slotIndex: u256(datasetSlotIndex)
    )

  proc createSlotBlocks(): Future[void] {.async.} =
    slotBlocks = (await SlotBlocks.new(slot, localStore)).tryGet()

  setup:
    await createDatasetBlocks()
    await createManifest()
    createSlot()
    discard await localStore.putBlock(manifestBlock)
    await createSlotBlocks()

  for input in 0 ..< numberOfSlotBlocks:
    test "Can get datasetBlockIndex from slotBlockIndex (" & $input & ")":
      let
        slotBlockIndex = input.uint64
        datasetBlockIndex = slotBlocks.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex)
        datasetSlotIndex = slot.slotIndex.truncate(uint64)
        expectedIndex = (numberOfSlotBlocks.uint64 * datasetSlotIndex) + slotBlockIndex

      check:
        datasetBlockIndex == expectedIndex

  for input in [0, 1, numberOfSlotBlocks-1]:
    test "Can get slot block by index (" & $input & ")":
      let
        slotBlockIndex = input.uint64
        slotBlock = (await slotBlocks.getSlotBlock(slotBlockIndex)).tryget()
        expectedDatasetBlockIndex = slotBlocks.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex)
        expectedBlock = datasetBlocks[expectedDatasetBlockIndex]

      check:
        slotBlock.cid == expectedBlock.cid
        slotBlock.data == expectedBlock.data

  test "Can fail to get block when index is out of range":
    let
      b1 = await slotBlocks.getSlotBlock(numberOfSlotBlocks.uint64)
      b2 = await slotBlocks.getSlotBlock((numberOfSlotBlocks + 1).uint64)

    check:
      b1.isErr
      b2.isErr
