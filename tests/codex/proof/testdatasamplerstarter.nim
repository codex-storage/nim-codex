import std/sequtils

import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/asynctest
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore

import pkg/codex/proof/datasamplerstarter
import pkg/codex/slots/converters
import pkg/codex/utils/digest
import pkg/codex/slots/slotbuilder

import ../helpers
import ../examples
import ../merkletree/helpers

let
  bytesPerBlock = 64 * 1024
  challenge: Poseidon2Hash = toF(12345)

asyncchecksuite "Test datasampler starter":
  let
    # The number of slot blocks and number of slots, combined with
    # the bytes per block, make it so that there are exactly 256 cells
    # in the dataset.
    numberOfSlotBlocks = 4
    totalNumberOfSlots = 2
    datasetSlotIndex = 1
    localStore = CacheStore.new()
    datasetToSlotProof = Poseidon2Proof.example

  var
    manifest: Manifest
    manifestBlock: bt.Block
    slot: Slot
    datasetBlocks: seq[bt.Block]
    slotTree: Poseidon2Tree
    slotRoots: seq[Poseidon2Hash]
    datasetToSlotTree: Poseidon2Tree
    datasetRootHash: Poseidon2Hash

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
      datasetBlockIndexFirst = datasetSlotIndex * blocksInSlot
      datasetBlockIndexLast = datasetBlockIndexFirst + numberOfSlotBlocks.uint64
      slotBlocks = datasetBlocks[datasetBlockIndexFirst ..< datasetBlockIndexLast]
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
    slotRoots = slotTrees.mapIt(it.root().tryGet())
    let rootsPadLeafs = newSeqWith(totalNumberOfSlots.nextPowerOfTwoPad, Poseidon2Zero)
    datasetToSlotTree = Poseidon2Tree.init(slotRoots & rootsPadLeafs).tryGet()
    datasetRootHash = datasetToSlotTree.root().tryGet()

  proc createManifest(): Future[void] {.async.} =
    let
      # cids = datasetBlocks.mapIt(it.cid)
      # tree = Poseidon2Tree.init(cids.mapIt(Sponge.digest(it.data.buffer, rate = 2))).tryGet()
      treeCid = datasetRootHash.toProvingCid().tryGet()

    # for index, leaf in tree.leaves:
    #   let
    #     leafCid = leaf.toCellCid().tryGet()
    #     proof = tree.getProof(index).tryGet().toEncodableProof().tryGet()
    #   discard await localStore.putCidAndProof(treeCid, index, leafCid, proof)

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

  setup:
    await createDatasetBlocks()
    await createDatasetRootHashAndSlotTree()
    await createManifest()
    createSlot()

  teardown:
    await localStore.close()
    reset(manifest)
    reset(manifestBlock)
    reset(slot)
    reset(datasetBlocks)
    reset(slotTree)
    reset(slotRoots)
    reset(datasetToSlotTree)
    reset(datasetRootHash)

  proc run(): Future[DataSamplerStarter] {.async.} =
    (await startDataSampler(localStore, manifest, slot)).tryGet()

  test "Returns dataset slot index":
    let start = await run()

    check:
      start.datasetSlotIndex == datasetSlotIndex.uint64

  test "Returns dataset-to-slot proof":
    let
      start = await run()
      expectedProof = datasetToSlotTree.getProof(datasetSlotIndex).tryGet()

    check:
      start.datasetToSlotProof == expectedProof

  test "Returns slot tree CID":
    let
      start = await run()
      expectedCid = slotTree.root().tryGet().toSlotCid().tryGet()

    check:
      start.slotTreeCid == expectedCid
