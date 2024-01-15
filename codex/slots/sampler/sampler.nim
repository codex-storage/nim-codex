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
    # The following data is invariant over time for a given slot:
    builder: SlotsBuilder

proc new*(
    T: type DataSampler,
    slot: Slot,
    blockStore: BlockStore,
    builder: SlotsBuilder): Future[?!DataSampler] {.async.} =
  # Create a DataSampler for a slot.
  # A DataSampler can create the input required for the proving circuit.
  let
    numberOfCellsInSlot = getNumberOfCellsInSlot(slot)
    blockSize = slotBlocks.manifest.blockSize.uint64

  success(DataSampler(
    slot: slot,
    blockStore: blockStore,
    slotBlocks: slotBlocks,
    datasetRoot: datasetRoot,
    slotRootHash: toF(1234), # TODO - when slotPoseidonTree is a poseidon tree, its root should be a FieldElement.
    slotPoseidonTree: slotPoseidonTree,
    datasetToSlotProof: datasetToSlotProof,
    blockSize: blockSize,
    numberOfCellsInSlot: numberOfCellsInSlot,
    datasetSlotIndex: slot.slotIndex.truncate(uint64),
    numberOfCellsPerBlock: blockSize div CellSize
  ))

proc getDatasetBlockIndexForSlotBlockIndex*(self: DataSampler, slotBlockIndex: uint64): uint64 =
  let
    slotSize = self.slot.request.ask.slotSize.truncate(uint64)
    blocksInSlot = slotSize div self.manifest.blockSize.uint64
    datasetSlotIndex = self.slot.slotIndex.truncate(uint64)
  return (datasetSlotIndex * blocksInSlot) + slotBlockIndex

proc getSlotBlock*(self: DataSampler, slotBlockIndex: uint64): Future[?!Block] {.async.} =
  let
    blocksInManifest = (self.manifest.datasetSize div self.manifest.blockSize).uint64
    datasetBlockIndex = self.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex)

  if datasetBlockIndex >= blocksInManifest:
    return failure("Found datasetBlockIndex that is out-of-range: " & $datasetBlockIndex)

  return await self.blockStore.getBlock(self.manifest.treeCid, datasetBlockIndex)

proc convertToSlotCellIndex(self: DataSampler, fe: FieldElement): uint64 =
  let
    n = self.numberOfCellsInSlot.int
    log2 = ceilingLog2(n)
  assert((1 shl log2) == n , "expected `numberOfCellsInSlot` to be a power of two.")

  return extractLowBits(fe.toBig(), log2)

func getSlotBlockIndexForSlotCellIndex*(self: DataSampler, slotCellIndex: uint64): uint64 =
  return slotCellIndex div self.numberOfCellsPerBlock

func getBlockCellIndexForSlotCellIndex*(self: DataSampler, slotCellIndex: uint64): uint64 =
  return slotCellIndex mod self.numberOfCellsPerBlock

proc findSlotCellIndex*(self: DataSampler, challenge: FieldElement, counter: FieldElement): uint64 =
  # Computes the slot-cell index for a single sample.
  let
    input = @[self.slotRootHash, challenge, counter]
    hash = Sponge.digest(input, rate = 2)
  return convertToSlotCellIndex(self, hash)

func findSlotCellIndices*(self: DataSampler, challenge: FieldElement, nSamples: int): seq[uint64] =
  # Computes nSamples slot-cell indices.
  return collect(newSeq, (for i in 1..nSamples: self.findSlotCellIndex(challenge, toF(i))))

proc getCellFromBlock*(self: DataSampler, blk: bt.Block, slotCellIndex: uint64): Cell =
  let
    blockCellIndex = self.getBlockCellIndexForSlotCellIndex(slotCellIndex)
    dataStart = (CellSize * blockCellIndex)
    dataEnd = dataStart + CellSize
  return blk.data[dataStart ..< dataEnd]

proc getBlockCells*(self: DataSampler, blk: bt.Block): seq[Cell] =
  var cells: seq[Cell]
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

proc getProofInput*(self: DataSampler, challenge: FieldElement, nSamples: int): Future[?!ProofInput] {.async.} =
  var
    slotToBlockProofs: seq[MerkleProof]
    blockToCellProofs: seq[MerkleProof]
    samples: seq[ProofSample]

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

    proc combine(bottom: MerkleProof, top: MerkleProof): MerkleProof =
      return bottom

    samples.add(ProofSample(
      cellData: cell,
      merkleProof: combine(cellProof, blockProof)
    ))

  trace "Successfully collected proof input"
  success(ProofInput(
    datasetRoot: self.datasetRoot,
    entropy: challenge,
    numberOfCellsInSlot: self.numberOfCellsInSlot,
    numberOfSlots: self.slot.request.ask.slots,
    datasetSlotIndex: self.datasetSlotIndex,
    slotRoot: self.slotRootHash,
    datasetToSlotProof: self.datasetToSlotProof,
    proofSamples: samples
  ))
