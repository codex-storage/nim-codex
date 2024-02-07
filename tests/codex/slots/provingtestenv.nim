import std/sequtils
import std/math

import pkg/questionable/results
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore
import pkg/codex/indexingstrategy

import pkg/codex/slots/converters
import pkg/codex/slots/builder/builder
import pkg/codex/utils/poseidon2digest
import pkg/codex/utils/asynciter

import ../helpers
import ../merkletree/helpers

const
  # The number of slot blocks and number of slots, combined with
  # the bytes per block, make it so that there are exactly 256 cells
  # in the dataset.
  bytesPerBlock* = 64 * 1024
  cellsPerBlock* = bytesPerBlock div DefaultCellSize.int
  numberOfSlotBlocks* = 3
  numberOfSlotBlocksPadded* = numberOfSlotBlocks.nextPowerOfTwo
  totalNumberOfSlots* = 2
  datasetSlotIndex* = 1
  cellsPerSlot* = (bytesPerBlock * numberOfSlotBlocks) div DefaultCellSize.int
  totalNumCells = ((numberOfSlotBlocks * totalNumberOfSlots * bytesPerBlock) div DefaultCellSize.int)

type
  ProvingTestEnvironment* = ref object
    # Invariant:
    # These challenges are chosen such that with the testenv default values
    # and nSamples=3, they will land on [3x data cells + 0x padded cell],
    # and [2x data cells + 1x padded cell] respectively:
    challengeNoPad*: Poseidon2Hash
    challengeOnePad*: Poseidon2Hash
    blockPadBytes*: seq[byte]
    emptyBlockTree*: Poseidon2Tree
    emptyBlockCid*: Cid
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
  var data: seq[byte] = @[]

  # This generates a number of blocks that have different data, such that
  # Each cell in each block is unique, but nothing is random.
  for i in 0 ..< totalNumCells:
    data = data & (i.byte).repeat(DefaultCellSize.uint64)

  let chunker = MockChunker.new(
    dataset = data,
    chunkSize = bytesPerBlock)

  while true:
    let chunk = await chunker.getBytes()
    if chunk.len <= 0:
      break
    let b = bt.Block.new(chunk).tryGet()
    self.datasetBlocks.add(b)
    discard await self.localStore.putBlock(b)

proc createSlotTree(self: ProvingTestEnvironment, dSlotIndex: uint64): Future[Poseidon2Tree] {.async.} =
  let
    slotSize = (bytesPerBlock * numberOfSlotBlocks).uint64
    blocksInSlot = slotSize div bytesPerBlock.uint64
    datasetBlockIndexingStrategy = SteppedStrategy.init(0, self.datasetBlocks.len - 1, totalNumberOfSlots)
    datasetBlockIndices = toSeq(datasetBlockIndexingStrategy.getIndicies(dSlotIndex.int))

  let
    slotBlocks = datasetBlockIndices.mapIt(self.datasetBlocks[it])
    slotBlockRoots = slotBlocks.mapIt(Poseidon2Tree.digest(it.data & self.blockPadBytes, DefaultCellSize.int).tryGet())
    slotBlockRootPads = newSeqWith((slotBlockRoots.len).nextPowerOfTwoPad, Poseidon2Zero)
    tree = Poseidon2Tree.init(slotBlockRoots & slotBlockRootPads).tryGet()
    treeCid = tree.root().tryGet().toSlotCid().tryGet()

  for i in 0 ..< numberOfSlotBlocksPadded:
    var blkCid: Cid
    if i < slotBlockRoots.len:
      blkCid = slotBlockRoots[i].toCellCid().tryGet()
    else:
      blkCid = self.emptyBlockCid

    let proof = tree.getProof(i).tryGet().toEncodableProof().tryGet()
    discard await self.localStore.putCidAndProof(treeCid, i, blkCid, proof)

  return tree

proc createDatasetRootHashAndSlotTree(self: ProvingTestEnvironment): Future[void] {.async.} =
  var slotTrees = newSeq[Poseidon2Tree]()
  for i in 0 ..< totalNumberOfSlots:
    slotTrees.add(await self.createSlotTree(i.uint64))
  self.slotTree = slotTrees[datasetSlotIndex]
  self.slotRootCid = slotTrees[datasetSlotIndex].root().tryGet().toSlotCid().tryGet()
  self.slotRoots = slotTrees.mapIt(it.root().tryGet())
  let rootsPadLeafs = newSeqWith(totalNumberOfSlots.nextPowerOfTwoPad, Poseidon2Zero)
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
    blockSize = bytesPerBlock.NBytes,
    datasetSize = (bytesPerBlock * numberOfSlotBlocks * totalNumberOfSlots).NBytes)

  # Protected manifest:
  self.manifest = Manifest.new(
    manifest = self.manifest,
    treeCid = treeCid,
    datasetSize = self.manifest.datasetSize,
    ecK = totalNumberOfSlots,
    ecM = 0
  )

  # Verifiable manifest:
  self.manifest = Manifest.new(
    manifest = self.manifest,
    verifyRoot = self.datasetRootHash.toVerifyCid().tryGet(),
    slotRoots = self.slotRoots.mapIt(it.toSlotCid().tryGet())
  ).tryGet()

  self.manifestBlock = bt.Block.new(self.manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
  discard await self.localStore.putBlock(self.manifestBlock)

proc createSlot(self: ProvingTestEnvironment): void =
  self.slot = Slot(
    request: StorageRequest(
      ask: StorageAsk(
        slots: totalNumberOfSlots.uint64,
        slotSize: u256(bytesPerBlock * numberOfSlotBlocks)
      ),
      content: StorageContent(
        cid: $self.manifestBlock.cid
      ),
    ),
    slotIndex: u256(datasetSlotIndex)
  )

proc createProvingTestEnvironment*(): Future[ProvingTestEnvironment] {.async.} =
  let
    numBlockCells = bytesPerBlock.int div DefaultCellSize.int
    blockPadBytes = newSeq[byte](numBlockCells.nextPowerOfTwoPad * DefaultCellSize.int)
    emptyBlockTree = Poseidon2Tree.digestTree(DefaultEmptyBlock & blockPadBytes, DefaultCellSize.int).tryGet()
    emptyBlockCid = emptyBlockTree.root.tryGet().toCellCid().tryGet()

  var testEnv = ProvingTestEnvironment(
    challengeNoPad: toF(6),
    challengeOnePad: toF(9),
    blockPadBytes: blockPadBytes,
    emptyBlockTree: emptyBlockTree,
    emptyBlockCid: emptyBlockCid
  )

  testEnv.localStore = CacheStore.new()
  await testEnv.createDatasetBlocks()
  await testEnv.createDatasetRootHashAndSlotTree()
  await testEnv.createManifest()
  testEnv.createSlot()

  return testEnv
