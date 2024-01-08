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
import pkg/codex/indexingstrategy

import pkg/codex/proof/datasamplerstarter
import pkg/codex/slots/converters
import pkg/codex/utils/digest
import pkg/codex/slots/slotbuilder

import ../helpers
import ../examples
import ../merkletree/helpers

type
  ProvingTestEnvironment* = ref object
    # Invariant:
    bytesPerBlock*: int
    numberOfSlotBlocks*: int
    totalNumberOfSlots*: int
    datasetSlotIndex*: int
    challenge*: Poseidon2Hash
    # Variant:
    localStore*: CacheStore
    manifest*: Manifest
    manifestBlock*: bt.Block
    slot*: Slot
    datasetBlocks*: seq[bt.Block]
    slotTree*: Poseidon2Tree
    slotRootCid*: Cid
    slotRoots*: seq[Poseidon2Hash]
    datasetToSlotTree*: Poseidon2Tree
    datasetRootHash*: Poseidon2Hash

proc createDatasetBlocks(self: ProvingTestEnvironment): Future[void] {.async.} =
  let numberOfCellsNeeded = (self.numberOfSlotBlocks * self.totalNumberOfSlots * self.bytesPerBlock).uint64 div DefaultCellSize.uint64
  var data: seq[byte] = @[]

  # This generates a number of blocks that have different data, such that
  # Each cell in each block is unique, but nothing is random.
  for i in 0 ..< numberOfCellsNeeded:
    data = data & (i.byte).repeat(DefaultCellSize.uint64)

  let chunker = MockChunker.new(
    dataset = data,
    chunkSize = self.bytesPerBlock)

  while true:
    let chunk = await chunker.getBytes()
    if chunk.len <= 0:
      break
    let b = bt.Block.new(chunk).tryGet()
    self.datasetBlocks.add(b)
    discard await self.localStore.putBlock(b)

proc createSlotTree(self: ProvingTestEnvironment, datasetSlotIndex: uint64): Future[Poseidon2Tree] {.async.} =
  let
    slotSize = (self.bytesPerBlock * self.numberOfSlotBlocks).uint64
    blocksInSlot = slotSize div self.bytesPerBlock.uint64
    datasetBlockIndexingStrategy = SteppedIndexingStrategy.new(0, self.datasetBlocks.len - 1, self.totalNumberOfSlots)
    datasetBlockIndices = datasetBlockIndexingStrategy.getIndicies(datasetSlotIndex.int)

  let
    slotBlocks = datasetBlockIndices.mapIt(self.datasetBlocks[it])
    slotBlockRoots = slotBlocks.mapIt(Poseidon2Tree.digest(it.data, DefaultCellSize.int).tryGet())
    tree = Poseidon2Tree.init(slotBlockRoots).tryGet()
    treeCid = tree.root().tryGet().toSlotCid().tryGet()

  for i in 0 ..< self.numberOfSlotBlocks:
    let
      blkCid = slotBlockRoots[i].toCellCid().tryGet()
      proof = tree.getProof(i).tryGet().toEncodableProof().tryGet()

    discard await self.localStore.putCidAndProof(treeCid, i, blkCid, proof)

  return tree

proc createDatasetRootHashAndSlotTree(self: ProvingTestEnvironment): Future[void] {.async.} =
  var slotTrees = newSeq[Poseidon2Tree]()
  for i in 0 ..< self.totalNumberOfSlots:
    slotTrees.add(await self.createSlotTree(i.uint64))
  self.slotTree = slotTrees[self.datasetSlotIndex]
  self.slotRootCid = slotTrees[self.datasetSlotIndex].root().tryGet().toSlotCid().tryGet()
  self.slotRoots = slotTrees.mapIt(it.root().tryGet())
  let rootsPadLeafs = newSeqWith(self.totalNumberOfSlots.nextPowerOfTwoPad, Poseidon2Zero)
  self.datasetToSlotTree = Poseidon2Tree.init(self.slotRoots & rootsPadLeafs).tryGet()
  self.datasetRootHash = self.datasetToSlotTree.root().tryGet()

proc createManifest(self: ProvingTestEnvironment): Future[void] {.async.} =
  let
    cids = self.datasetBlocks.mapIt(it.cid)
    tree = CodexTree.init(cids).tryGet()
    treeCid = tree.rootCid(CIDv1, BlockCodec).tryGet()

  for i in 0 ..< self.datasetBlocks.len:
    let
      blk = self.datasetBlocks[i]
      leafCid = blk.cid
      proof = tree.getProof(i).tryGet()
    discard await self.localStore.putBlock(blk)
    discard await self.localStore.putCidAndProof(treeCid, i, leafCid, proof)

  # Basic manifest:
  self.manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = self.bytesPerBlock.NBytes,
    datasetSize = (self.bytesPerBlock * self.numberOfSlotBlocks * self.totalNumberOfSlots).NBytes)

  # Protected manifest:
  self.manifest = Manifest.new(
    manifest = self.manifest,
    treeCid = treeCid,
    datasetSize = self.manifest.datasetSize,
    ecK = self.totalNumberOfSlots,
    ecM = 0
  )

  # Verifiable manifest:
  self.manifest = Manifest.new(
    manifest = self.manifest,
    verificationRoot = self.datasetRootHash.toProvingCid().tryGet(),
    slotRoots = self.slotRoots.mapIt(it.toSlotCid().tryGet())
  ).tryGet()

  self.manifestBlock = bt.Block.new(self.manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
  discard await self.localStore.putBlock(self.manifestBlock)

proc createSlot(self: ProvingTestEnvironment): void =
  self.slot = Slot(
    request: StorageRequest(
      ask: StorageAsk(
        slotSize: u256(self.bytesPerBlock * self.numberOfSlotBlocks)
      ),
      content: StorageContent(
        cid: $self.manifestBlock.cid
      ),
    ),
    slotIndex: u256(self.datasetSlotIndex)
  )

proc createProvingTestEnvironment*(): Future[ProvingTestEnvironment] {.async.} =
  var testEnv = ProvingTestEnvironment(
    challenge: toF(12345),
    # The number of slot blocks and number of slots, combined with
    # the bytes per block, make it so that there are exactly 256 cells
    # in the dataset.
    bytesPerBlock: 64 * 1024,
    numberOfSlotBlocks: 4,
    totalNumberOfSlots: 2,
    datasetSlotIndex: 1,
  )

  testEnv.localStore = CacheStore.new()
  await testEnv.createDatasetBlocks()
  await testEnv.createDatasetRootHashAndSlotTree()
  await testEnv.createManifest()
  testEnv.createSlot()

  return testEnv
