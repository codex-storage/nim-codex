import std/sequtils
import std/math
import pkg/chronos
import pkg/asynctest
import pkg/questionable/results
import pkg/codex/blocktype as bt
import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/chunker
import pkg/codex/merkletree
import pkg/codex/utils

import ../helpers
import ../examples

import codex/manifest/indexingstrategy
import codex/slotbuilder/slotbuilder

asyncchecksuite "Slot builder":
  let
    blockSize = 64 * 1024
    numberOfCellsPerBlock = blockSize div CellSize
    numberOfSlotBlocks = 6
    numberOfSlots = 5
    numberOfDatasetBlocks = numberOfSlotBlocks * numberOfSlots
    datasetSize = numberOfDatasetBlocks * blockSize
    chunker = RandomChunker.new(Rng.instance(), size = datasetSize, chunkSize = blockSize)

  var
    datasetBlocks: seq[bt.Block]
    localStore = CacheStore.new()
    protectedManifest: Manifest
    expectedEmptyCid: Cid
    slotBuilder: SlotBuilder

  proc createBlocks(): Future[void] {.async.} =
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break
      let blk = bt.Block.new(chunk).tryGet()
      datasetBlocks.add(blk)
      discard await localStore.putBlock(blk)

  proc createProtectedManifest(): Future[void] {.async.} =
    let
      cids = datasetBlocks.mapIt(it.cid)
      tree = MerkleTree.init(cids).tryGet()
      treeCid = tree.rootCid().tryGet()

    for index, cid in cids:
      let proof = tree.getProof(index).tryget()
      discard await localStore.putBlockCidAndProof(treeCid, index, cid, proof)

    protectedManifest = Manifest.new(
      manifest = Manifest.new(
        treeCid = treeCid,
        blockSize = blockSize.NBytes,
        datasetSize = datasetSize.NBytes),
      treeCid = treeCid,
      datasetSize = datasetSize.NBytes,
      ecK = numberOfSlots,
      ecM = 0
    )

    let manifestBlock = bt.Block.new(protectedManifest.encode().tryGet(), codec = DagPBCodec).tryGet()
    discard await localStore.putBlock(manifestBlock)
    expectedEmptyCid = emptyCid(protectedManifest.version, protectedManifest.hcodec, protectedManifest.codec).tryget()

  setup:
    await createBlocks()
    await createProtectedManifest()
    slotBuilder = SlotBuilder.new(localStore, protectedManifest).tryGet()

  test "Can only create slotBuilder with protected manifest":
    let unprotectedManifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = blockSize.NBytes,
      datasetSize = datasetSize.NBytes)

    check:
      SlotBuilder.new(localStore, unprotectedManifest).isErr

  test "Number of blocks must be devisable by number of slots":
    let mismatchManifest = Manifest.new(
      manifest = Manifest.new(
        treeCid = Cid.example,
        blockSize = blockSize.NBytes,
        datasetSize = datasetSize.NBytes),
      treeCid = Cid.example,
      datasetSize = datasetSize.NBytes,
      ecK = numberOfSlots - 1,
      ecM = 0
    )

    check:
      SlotBuilder.new(localStore, mismatchManifest).isErr

  test "Block size must be divisable by cell size":
    let mismatchManifest = Manifest.new(
      manifest = Manifest.new(
        treeCid = Cid.example,
        blockSize = (blockSize - 1).NBytes,
        datasetSize = (datasetSize - numberOfDatasetBlocks).NBytes),
      treeCid = Cid.example,
      datasetSize = (datasetSize - numberOfDatasetBlocks).NBytes,
      ecK = numberOfSlots,
      ecM = 0
    )

    check:
      SlotBuilder.new(localStore, mismatchManifest).isErr

  for nSlotBlocks in [1, 12, 123, 1234, 12345]:
    test "Can calculate the number of padding cells (" & $nSlotBlocks & ")":
      let
        nPadCells = slotBuilder.calculateNumberOfPaddingCells(nSlotBlocks)
        totalSlotBytes = nSlotBlocks * blockSize
        totalSlotCells = totalSlotBytes div CellSize
        expectedPadCells = nextPowerOfTwo(totalSlotCells) - totalSlotCells
      check:
        expectedPadCells == nPadCells

  for i in 0 ..< numberOfSlots:
    test "Can select slot block CIDs (index: " & $i & ")":
      let
        steppedStrategy = SteppedIndexingStrategy.new(0, numberOfDatasetBlocks - 1, numberOfSlots)
        expectedDatasetBlockIndicies = steppedStrategy.getIndicies(i)
        expectedBlockCids = expectedDatasetBlockIndicies.mapIt(datasetBlocks[it].cid)

        slotBlockCids = (await slotBuilder.selectSlotBlocks(i)).tryGet()

      check:
        expectedBlockCids == slotBlockCids

    test "Can create slot tree (index: " & $i & ")":
      let
        expectedSlotBlockCids = (await slotBuilder.selectSlotBlocks(i)).tryGet()
        expectedNumPadBlocks = divUp(slotBuilder.calculateNumberOfPaddingCells(expectedSlotBlockCids.len), numberOfCellsPerBlock)

        slotTree = (await slotBuilder.createSlotTree(i)).tryGet()

      check:
        # Tree size
        slotTree.leavesCount == expectedSlotBlockCids.len + expectedNumPadBlocks

      for i in 0 ..< numberOfSlotBlocks:
        check:
          # Each slot block
          slotTree.getLeafCid(i).tryget() == expectedSlotBlockCids[i]

      for i in 0 ..< expectedNumPadBlocks:
        check:
          # Each pad block
          slotTree.getLeafCid(numberOfSlotBlocks + i).tryget() == expectedEmptyCid

  test "Can create slot tree":
    let
      slotBlockCids = datasetBlocks[0 ..< numberOfSlotBlocks].mapIt(it.cid)
      numPadCells = numberOfCellsPerBlock div 2 # We expect 1 pad block.

      slotTree = slotBuilder.buildSlotTree(slotBlockCids, numPadCells).tryGet()

    check:
      # Tree size
      slotTree.leavesCount == slotBlockCids.len + 1

    for i in 0 ..< numberOfSlotBlocks:
      check:
        # Each slot block
        slotTree.getLeafCid(i).tryget() == slotBlockCids[i]

    check:
      # 1 pad block
      slotTree.getLeafCid(numberOfSlotBlocks).tryget() == expectedEmptyCid

