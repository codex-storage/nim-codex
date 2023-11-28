import pkg/poseidon2/types
import ../merkletree

const
  # Size of a cell.
  # A cell is a sample of storage-data selected for proving.
  CellSize* = 2048.uint64

type
  FieldElement* = F
  Cell* = seq[byte]
  ProofSample* = ref object
    cellData*: Cell
    slotBlockIndex*: uint64
    cellBlockProof*: MerkleProof
    blockCellIndex*: uint64
    blockSlotProof*: MerkleProof
  ProofInput* = ref object
    datasetRoot*: FieldElement
    entropy*: FieldElement
    numberOfCellsInSlot*: uint64
    numberOfSlots*: uint64
    datasetSlotIndex*: uint64
    slotRoot*: FieldElement
    datasetToSlotProof*: MerkleProof
    proofSamples*: seq[ProofSample]
