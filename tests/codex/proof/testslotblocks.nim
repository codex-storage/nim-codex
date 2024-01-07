import std/sequtils

import pkg/chronos
import pkg/asynctest
import pkg/stew/arrayops
import pkg/codex/rng
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/indexingstrategy

import pkg/codex/proof/slotblocks
import pkg/codex/slots/converters
import pkg/codex/indexingstrategy
import pkg/codex/utils/digest
import pkg/codex/slots/slotbuilder

import ../helpers
import ../examples
import ../merkletree/helpers

let
  bytesPerBlock = 64 * 1024
  numberOfSlotBlocks = 4
  datasetSlotIndex = 3

# asyncchecksuite "Test slotblocks - manifest":
#   let
#     localStore = CacheStore.new()
#     manifest = Manifest.new(
#       treeCid = Cid.example,
#       blockSize = 1.MiBs,
#       datasetSize = 100.MiBs)

#   var
#     manifestBlock = bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
#     slot = Slot(
#       request: StorageRequest(
#         ask: StorageAsk(
#           slotSize: u256(bytesPerBlock * numberOfSlotBlocks)
#         ),
#         content: StorageContent(
#           cid: $manifestBlock.cid
#         ),
#       ),
#       slotIndex: u256(datasetSlotIndex)
#     )

#   setup:
#     discard await localStore.putBlock(manifestBlock)

asyncchecksuite "Test slotblocks - slot blocks by index":
  let
    # The number of slot blocks and number of slots, combined with
    # the bytes per block, make it so that there are exactly 256 cells
    # in the dataset.
    numberOfSlotBlocks = 4
    totalNumberOfSlots = 2
    datasetSlotIndex = 1
    localStore = CacheStore.new()

  var
    manifest: Manifest
    manifestBlock: bt.Block
    slot: Slot
    datasetBlocks: seq[bt.Block]
    slotTree: Poseidon2Tree
    slotRootCid: Cid
    slotRoots: seq[Poseidon2Hash]
    datasetToSlotTree: Poseidon2Tree
    datasetRootHash: Poseidon2Hash
    slotBlocks: SlotBlocks

  proc createDatasetBlocks(): Future[void] {.async.} =
    let numberOfCellsNeeded = (numberOfSlotBlocks * totalNumberOfSlots * bytesPerBlock).uint64 div DefaultCellSize.uint64
    var data: seq[byte] = @[]

    # This generates a number of blocks that have different data, such that
    # Each cell in each block is unique, but nothing is random.
    for i in 0 ..< numberOfCellsNeeded:
      data = data & (i.byte).repeat(DefaultCellSize.uint64)

    let chunker = MockChunker.new(
      dataset = data,
      chunkSize = bytesPerBlock)

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break
      let b = bt.Block.new(chunk).tryGet()
      datasetBlocks.add(b)
      discard await localStore.putBlock(b)

  proc createSlotTree(datasetSlotIndex: uint64): Future[Poseidon2Tree] {.async.} =
    let
      slotSize = (bytesPerBlock * numberOfSlotBlocks).uint64
      blocksInSlot = slotSize div bytesPerBlock.uint64
      datasetBlockIndexingStrategy = SteppedIndexingStrategy.new(0, datasetBlocks.len - 1, totalNumberOfSlots)
      datasetBlockIndices = datasetBlockIndexingStrategy.getIndicies(datasetSlotIndex.int)

    let
      slotBlocks = datasetBlockIndices.mapIt(datasetBlocks[it])
      slotBlockRoots = slotBlocks.mapIt(Poseidon2Tree.digest(it.data, DefaultCellSize.int).tryGet())
      slotTree = Poseidon2Tree.init(slotBlockRoots).tryGet()
      slotTreeCid = slotTree.root().tryGet().toSlotCid().tryGet()

    for i in 0 ..< numberOfSlotBlocks:
      let
        blkCid = slotBlockRoots[i].toCellCid().tryGet()
        proof = slotTree.getProof(i).tryGet().toEncodableProof().tryGet()

      discard await localStore.putCidAndProof(slotTreeCid, i, blkCid, proof)

    return slotTree

  proc createDatasetRootHashAndSlotTree(): Future[void] {.async.} =
    var slotTrees = newSeq[Poseidon2Tree]()
    for i in 0 ..< totalNumberOfSlots:
      slotTrees.add(await createSlotTree(i.uint64))
    slotTree = slotTrees[datasetSlotIndex]
    slotRootCid = slotTrees[datasetSlotIndex].root().tryGet().toSlotCid().tryGet()
    slotRoots = slotTrees.mapIt(it.root().tryGet())
    let rootsPadLeafs = newSeqWith(totalNumberOfSlots.nextPowerOfTwoPad, Poseidon2Zero)
    datasetToSlotTree = Poseidon2Tree.init(slotRoots & rootsPadLeafs).tryGet()
    datasetRootHash = datasetToSlotTree.root().tryGet()

  proc createManifest(): Future[void] {.async.} =
    let
      cids = datasetBlocks.mapIt(it.cid)
      tree = CodexTree.init(cids).tryGet()
      treeCid = tree.rootCid(CIDv1, BlockCodec).tryGet()

    for i in 0 ..< datasetBlocks.len:
      let
        blk = datasetBlocks[i]
        leafCid = blk.cid
        proof = tree.getProof(i).tryGet()
      discard await localStore.putBlock(blk)
      discard await localStore.putCidAndProof(treeCid, i, leafCid, proof)

    # Basic manifest:
    manifest = Manifest.new(
      treeCid = treeCid,
      blockSize = bytesPerBlock.NBytes,
      datasetSize = (bytesPerBlock * numberOfSlotBlocks * totalNumberOfSlots).NBytes)

    # Protected manifest:
    manifest = Manifest.new(
      manifest = manifest,
      treeCid = treeCid,
      datasetSize = (bytesPerBlock * numberOfSlotBlocks * totalNumberOfSlots).NBytes,
      ecK = totalNumberOfSlots,
      ecM = 0
    )

    # Verifiable manifest:
    manifest = Manifest.new(
      manifest = manifest,
      verificationRoot = datasetRootHash.toProvingCid().tryGet(),
      slotRoots = slotRoots.mapIt(it.toSlotCid().tryGet())
    ).tryGet()

    manifestBlock = bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
    discard await localStore.putBlock(manifestBlock)

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
    await createDatasetRootHashAndSlotTree()
    await createManifest()
    createSlot()
    await createSlotBlocks()

  teardown:
    await localStore.close()
    reset(manifest)
    reset(manifestBlock)
    reset(slot)
    reset(datasetBlocks)
    reset(slotTree)
    reset(slotRootCid)
    reset(slotRoots)
    reset(datasetToSlotTree)
    reset(datasetRootHash)
    reset(slotBlocks)

  test "Can get manifest for slot":
    let m = slotBlocks.manifest

    check:
      m.treeCid == manifest.treeCid

  test "Can fail to get manifest for invalid cid":
    slot.request.content.cid = "invalid"
    let s = (await SlotBlocks.new(slot, localStore))

    check:
      s.isErr

  test "Can fail to get manifest when manifest block not found":
    let
      emptyStore = CacheStore.new()
      s = (await SlotBlocks.new(slot, emptyStore))

    check:
      s.isErr

  test "Can fail to get manifest when manifest fails to decode":
    manifestBlock.data = @[]

    let s = (await SlotBlocks.new(slot, localStore))

    check:
      s.isErr

  for input in 0 ..< numberOfSlotBlocks:
    test "Can get datasetBlockIndex from slotBlockIndex (" & $input & ")":
      let
        strategy = SteppedIndexingStrategy.new(0, manifest.blocksCount - 1, totalNumberOfSlots)
        slotBlockIndex = input.uint64
        datasetBlockIndex = slotBlocks.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex).tryGet()
        datasetSlotIndex = slot.slotIndex.truncate(uint64)
        expectedIndex = strategy.getIndicies(datasetSlotIndex.int)[slotBlockIndex]

      check:
        datasetBlockIndex == expectedIndex

  for input in [0, 1, numberOfSlotBlocks-1]:
    test "Can get slot block by index (" & $input & ")":
      let
        slotBlockIndex = input.uint64
        slotBlock = (await slotBlocks.getSlotBlock(slotBlockIndex)).tryget()
        expectedDatasetBlockIndex = slotBlocks.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex).tryGet()
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
