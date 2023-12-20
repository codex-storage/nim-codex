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
import ../utils/digest

const
  # TODO: Unified with the CellSize specified in branch "data-sampler"
  # Number of bytes in a cell. A cell is the smallest unit of data used
  # in the proving circuit.
  CellSize* = 2048

type
  SlotBuilder* = object of RootObj
    blockStore: BlockStore
    manifest: Manifest
    slotBlocks: int

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

  let slotBlocks = manifest.blocksCount div manifest.numberOfSlots
  success SlotBuilder(
    blockStore: blockStore,
    manifest: manifest,
    slotBlocks: slotBlocks)

proc cellsPerBlock(self: SlotBuilder): int =
  self.manifest.blockSize.int div CellSize

proc selectSlotBlocks*(
  self: SlotBuilder,
  slotIndex: int): Future[?!seq[Poseidon2Hash]] {.async.} =

  let
    treeCid = self.manifest.treeCid
    blockCount = self.manifest.blocksCount
    numberOfSlots = self.manifest.numberOfSlots
    strategy = SteppedIndexingStrategy.new(0, blockCount - 1, numberOfSlots)

  logScope:
    treeCid = treeCid
    blockCount = blockCount
    numberOfSlots = numberOfSlots
    index = blockIndex

  var blocks = newSeq[Poseidon2Hash]()
  for blockIndex in strategy.getIndicies(slotIndex):
    without blk =? await self.blockStore.getBlock(treeCid, blockIndex), err:
      error "Failed to get block CID for tree at index"

      return failure(err)

    without digestTree =? Poseidon2Tree.digest(blk.data, CellSize) and
        blockDigest =? digestTree.root, err:
      error "Failed to create digest for block"

      return failure(err)

    blocks.add(blockDigest)
    # TODO: Remove this sleep. It's here to prevent us from locking up the thread.
    await sleepAsync(10.millis)

  success blocks

proc numPaddingCells*(self: SlotBuilder, slotBlocks: int): int =
  let
    numberOfCells = slotBlocks * self.cellsPerBlock
    nextPowerOfTwo = nextPowerOfTwo(numberOfCells)

  return nextPowerOfTwo - numberOfCells

proc buildSlotTree*(self: SlotBuilder, slotBlocks: seq[Cid], paddingCells: int): ?!Poseidon2Tree =
  without emptyCid =? emptyCid(self.manifest.version, self.manifest.hcodec, self.manifest.codec), err:
    error "Unable to initialize empty cid"
    return failure(err)

  let paddingBlocks = divUp(paddingCells, self.cellsPerBlock)
  let padding = newSeqWith(paddingBlocks, emptyCid)

  Poseidon2Tree.init(slotBlocks & padding)

proc createSlots*(self: SlotBuilder, slotIndex: int): Future[?!Manifest] {.async.} =
  without slotBlocks =? await self.selectSlotBlocks(slotIndex), err:
    error "Failed to select slot blocks"
    return failure(err)

  let paddingCells = self.numPaddingCells(slotBlocks.len)

  trace "Creating slot tree", slotIndex, nSlotBlocks = slotBlocks.len, paddingCells
  return self.buildSlotTree(slotBlocks, paddingCells)
