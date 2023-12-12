import std/math
import std/sequtils
import pkg/libp2p
import pkg/chronos
import pkg/chronicles
import pkg/questionable/results
import ../merkletree
import ../stores
import ../manifest
import ../utils

let
  # TODO: Unified with the CellSize specified in branch "data-sampler"
  # Number of bytes in a cell. A cell is the smallest unit of data used
  # in the proving circuit.
  CellSize* = 2048

type
  SlotBuilder* = object of RootObj
    blockStore: BlockStore
    manifest: Manifest
    numberOfSlotBlocks: int

proc new*(
    T: type SlotBuilder,
    blockStore: BlockStore,
    manifest: Manifest
): ?!SlotBuilder =

  if not manifest.protected:
    return failure("Can only create SlotBuilder using protected manifests.")

  if (manifest.blocksCount mod manifest.ecK) != 0:
    return failure("Number of blocks must be divisable by number of slots.")

  if (manifest.blockSize.int mod CellSize) != 0:
    return failure("Block size must be divisable by cell size.")

  let numberOfSlotBlocks = manifest.blocksCount div manifest.ecK
  success(SlotBuilder(
    blockStore: blockStore,
    manifest: manifest,
    numberOfSlotBlocks: numberOfSlotBlocks
  ))

proc cellsPerBlock(self: SlotBuilder): int =
  self.manifest.blockSize.int div CellSize

proc selectSlotBlocks*(self: SlotBuilder, datasetSlotIndex: int): Future[?!seq[Cid]] {.async.} =
  var cids = newSeq[Cid]()
  let
    datasetTreeCid = self.manifest.treeCid
    blockCount = self.manifest.blocksCount
    numberOfSlots = self.manifest.numberOfSlots
    strategy = SteppedIndexingStrategy.new(0, blockCount - 1, numberOfSlots)

  for datasetBlockIndex in strategy.getIndicies(datasetSlotIndex):
    without slotBlockCid =? await self.blockStore.getCid(datasetTreeCid, datasetBlockIndex), err:
      error "Failed to get block CID for tree at index", index=datasetBlockIndex, tree=datasetTreeCid
      return failure(err)
    cids.add(slotBlockCid)
    # TODO: Remove this sleep. It's here to prevent us from locking up the thread.
    await sleepAsync(10.millis)

  return success(cids)

proc calculateNumberOfPaddingCells*(self: SlotBuilder, numberOfSlotBlocks: int): int =
  let
    numberOfCells = numberOfSlotBlocks * self.cellsPerBlock
    nextPowerOfTwo = nextPowerOfTwo(numberOfCells)

  return nextPowerOfTwo - numberOfCells

proc buildSlotTree*(self: SlotBuilder, slotBlocks: seq[Cid], numberOfPaddingCells: int): ?!MerkleTree =
  without emptyCid =? emptyCid(self.manifest.version, self.manifest.hcodec, self.manifest.codec), err:
    error "Unable to initialize empty cid"
    return failure(err)

  let numberOfPadBlocks = divUp(numberOfPaddingCells, self.cellsPerBlock)
  let padding = newSeqWith(numberOfPadBlocks, emptyCid)

  MerkleTree.init(slotBlocks & padding)

proc createSlotTree*(self: SlotBuilder, datasetSlotIndex: int): Future[?!MerkleTree] {.async.} =
  without slotBlocks =? await self.selectSlotBlocks(datasetSlotIndex), err:
    error "Failed to select slot blocks"
    return failure(err)

  let numberOfPaddingCells = self.calculateNumberOfPaddingCells(slotBlocks.len)

  trace "Creating slot tree", datasetSlotIndex=datasetSlotIndex, nSlotBlocks=slotBlocks.len, nPaddingCells=numberOfPaddingCells
  return self.buildSlotTree(slotBlocks, numberOfPaddingCells)
