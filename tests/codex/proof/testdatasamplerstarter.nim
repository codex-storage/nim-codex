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

  proc createSlotTree(datasetSlotIndex: uint64): Poseidon2Tree =
    let
      slotSize = slot.request.ask.slotSize.truncate(uint64)
      blocksInSlot = slotSize div bytesPerBlock.uint64
      datasetBlockIndexFirst = datasetSlotIndex * blocksInSlot
      datasetBlockIndexLast = datasetBlockIndexFirst + numberOfSlotBlocks.uint64
      slotBlocks = datasetBlocks[datasetBlockIndexFirst ..< datasetBlockIndexLast]
      slotBlockRoots = slotBlocks.mapIt(Poseidon2Tree.digest(it.data, DefaultCellSize.int).tryGet())
    return Poseidon2Tree.init(slotBlockRoots).tryGet()

  proc createDatasetRootHashAndSlotTree(): void =
    var slotTrees = newSeq[Poseidon2Tree]()
    for i in 0 ..< totalNumberOfSlots:
      slotTrees.add(createSlotTree(i.uint64))
    slotTree = slotTrees[datasetSlotIndex]
    slotRoots = slotTrees.mapIt(it.root().tryGet())
    let rootsPadLeafs = newSeqWith(totalNumberOfSlots.nextPowerOfTwoPad, Poseidon2Zero)
    datasetRootHash = Poseidon2Tree.init(slotRoots & rootsPadLeafs).tryGet().root().tryGet()

  proc createManifest(): Future[void] {.async.} =
    let
      cids = datasetBlocks.mapIt(it.cid)
      tree = Poseidon2Tree.init(cids.mapIt(Sponge.digest(it.data.buffer, rate = 2))).tryGet()
      treeCid = tree.root().tryGet().toProvingCid().tryGet()

    for index, leaf in tree.leaves:
      let
        leafCid = leaf.toCellCid().tryGet()
        proof = tree.getProof(index).tryGet().toEncodableProof().tryGet()
      discard await localStore.putCidAndProof(treeCid, index, leafCid, proof)

    # Basic manifest:
    manifest = Manifest.new(
      treeCid = treeCid,
      blockSize = bytesPerBlock.NBytes,
      datasetSize = (bytesPerBlock * numberOfSlotBlocks * totalNumberOfSlots).NBytes)

    # Protected manifest:
    manifest = Manifest.new(
      manifest = manifest,
      treeCid = treeCid,
      blockSize = bytesPerBlock.NBytes,
      datasetSize = (bytesPerBlock * numberOfSlotBlocks * totalNumberOfSlots).NBytes,
      ecK = totalNumberOfSlots,
      ecM = 0
    )

    # Verifiable manifest:
    manifest = Manifest.new(
      manifest = manifest,
      verificationRoot = datasetRootHash.toProvingCid().tryGet(),
      slotRoots = slotRoots.mapIt(it.toSlotCid().tryGet())
    )

    manifestBlock = bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  setup:
    await createDatasetBlocks()
    createSlot()
    createslotTree()
    await createManifest()
    discard await localStore.putBlock(manifestBlock)

  proc run(): Future[DataSamplerStarter] {.async.} =
    (await startDataSampler(localStore, manifest, slot)).tryGet()

  test "Returns dataset slot index":
    let start = await run()

    check:
      start.datasetSlotIndex == datasetSlotIndex.uint64
