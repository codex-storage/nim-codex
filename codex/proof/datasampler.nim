import ../contracts/requests
import ../blocktype as bt
import ../merkletree
import ../manifest
import ../stores/blockstore

import std/bitops
import std/sugar

import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/poseidon2/types
import pkg/poseidon2

import misc
import slotblocks
import types

# Index naming convention:
# "<ContainerType><ElementType>Index" => The index of an ElementType within a ContainerType.
# Some examples:
# SlotBlockIndex => The index of a Block within a Slot.
# DatasetBlockIndex => The index of a Block within a Dataset.

logScope:
  topics = "codex datasampler"

type
  DataSampler* = ref object of RootObj
    slot: Slot
    blockStore: BlockStore
    slotBlocks: SlotBlocks
    # The following data is invariant over time for a given slot:
    slotRootHash: DSFieldElement
    slotPoseidonTree: MerkleTree
    datasetToSlotProof: MerkleProof
    blockSize: uint64
    numberOfCellsInSlot: uint64
    numberOfCellsPerBlock: uint64

proc getNumberOfCellsInSlot*(slot: Slot): uint64 =
  (slot.request.ask.slotSize.truncate(uint64) div CellSize)

proc new*(
    T: type DataSampler,
    slot: Slot,
    blockStore: BlockStore,
    slotRootHash: DSFieldElement,
    slotPoseidonTree: MerkleTree,
    datasetToSlotProof: MerkleProof
): Future[?!DataSampler] {.async.} =
  # Create a DataSampler for a slot.
  # A DataSampler can create the input required for the proving circuit.
  without slotBlocks =? await SlotBlocks.new(slot, blockStore), err:
    error "Failed to create SlotBlocks object for slot"
    return failure(err)

  let
    numberOfCellsInSlot = getNumberOfCellsInSlot(slot)
    blockSize = slotBlocks.manifest.blockSize.uint64

  success(DataSampler(
    slot: slot,
    blockStore: blockStore,
    slotBlocks: slotBlocks,
    slotRootHash: slotRootHash,
    slotPoseidonTree: slotPoseidonTree,
    datasetToSlotProof: datasetToSlotProof,
    blockSize: blockSize,
    numberOfCellsInSlot: numberOfCellsInSlot,
    numberOfCellsPerBlock: blockSize div CellSize
  ))

func extractLowBits*[n: static int](A: BigInt[n], k: int): uint64 =
  assert(k > 0 and k <= 64)
  var r: uint64 = 0
  for i in 0..<k:
    # A is big-endian. Run index backwards: n-1-i
    #let b = bit[n](A, n-1-i)
    let b = bit[n](A, i)

    let y = uint64(b)
    if (y != 0):
      r = bitor(r, 1'u64 shl i)
  return r

proc convertToSlotCellIndex(self: DataSampler, fe: DSFieldElement): uint64 =
  let
    n = self.numberOfCellsInSlot.int
    log2 = ceilingLog2(n)
  assert((1 shl log2) == n , "expected `numberOfCellsInSlot` to be a power of two.")

  return extractLowBits(fe.toBig(), log2)

proc getSlotBlockIndexForSlotCellIndex*(self: DataSampler, slotCellIndex: DSSlotCellIndex): uint64 =
  return slotCellIndex div self.numberOfCellsPerBlock

proc getBlockCellIndexForSlotCellIndex*(self: DataSampler, slotCellIndex: DSSlotCellIndex): uint64 =
  return slotCellIndex mod self.numberOfCellsPerBlock

proc findSlotCellIndex*(self: DataSampler, challenge: DSFieldElement, counter: DSFieldElement): DSSlotCellIndex =
  # Computes the slot-cell index for a single sample.
  let
    input = @[self.slotRootHash, challenge, counter]
    hash = Sponge.digest(input, rate = 2)
  return convertToSlotCellIndex(self, hash)

func findSlotCellIndices*(self: DataSampler, challenge: DSFieldElement, nSamples: int): seq[DSSlotCellIndex] =
  # Computes nSamples slot-cell indices.
  return collect(newSeq, (for i in 1..nSamples: self.findSlotCellIndex(challenge, toF(i))))

proc getCellFromBlock*(self: DataSampler, blk: bt.Block, slotCellIndex: DSSlotCellIndex): DSCell =
  let
    blockCellIndex = self.getBlockCellIndexForSlotCellIndex(slotCellIndex)
    dataStart = (CellSize * blockCellIndex)
    dataEnd = dataStart + CellSize

  return blk.data[dataStart ..< dataEnd]

proc getBlockCells*(self: DataSampler, blk: bt.Block): seq[DSCell] =
  var cells: seq[DSCell]
  for i in 0 ..< self.numberOfCellsPerBlock:
    cells.add(self.getCellFromBlock(blk, i))
  return cells

proc getBlockCellMiniTree*(self: DataSampler, blk: bt.Block): ?!MerkleTree =
  without var builder =? MerkleTreeBuilder.init(): # TODO tree with poseidon2 as hasher please
    error "Failed to create merkle tree builder"
    return failure("Failed to create merkle tree builder")

  let cells = self.getBlockCells(blk)
  for cell in cells:
    if builder.addDataBlock(cell).isErr:
      error "Failed to add cell data to tree"
      return failure("Failed to add cell data to tree")

  return builder.build()

proc getProofInput*(self: DataSampler, challenge: DSFieldElement, nSamples: int): Future[?!ProofInput] {.async.} =
  var
    slotToBlockProofs: seq[MerkleProof]
    blockToCellProofs: seq[MerkleProof]
    sampleData: seq[byte]

  let slotCellIndices = self.findSlotCellIndices(challenge, nSamples)

  trace "Collecing input for proof", selectedSlotCellIndices = $slotCellIndices
  for slotCellIndex in slotCellIndices:
    let
      slotBlockIndex = self.getSlotBlockIndexForSlotCellIndex(slotCellIndex)
      blockCellIndex = self.getBlockCellIndexForSlotCellIndex(slotCellIndex)

    without blk =? await self.slotBlocks.getSlotBlock(slotBlockIndex), err:
      error "Failed to get slot block"
      return failure(err)

    without miniTree =? self.getBlockCellMiniTree(blk), err:
      error "Failed to calculate minitree for block"
      return failure(err)

    without blockProof =? self.slotPoseidonTree.getProof(slotBlockIndex), err:
      error "Failed to get slot-to-block inclusion proof"
      return failure(err)
    slotToBlockProofs.add(blockProof)

    without cellProof =? miniTree.getProof(blockCellIndex), err:
      error "Failed to get block-to-cell inclusion proof"
      return failure(err)
    blockToCellProofs.add(cellProof)

    let cell = self.getCellFromBlock(blk, slotCellIndex)
    sampleData = sampleData & cell

  trace "Successfully collected proof input"
  success(ProofInput(
    datasetToSlotProof: self.datasetToSlotProof,
    slotToBlockProofs: slotToBlockProofs,
    blockToCellProofs: blockToCellProofs,
    sampleData: sampleData
  ))
