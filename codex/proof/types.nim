import pkg/poseidon2/types
import ../merkletree

const
  # Size of a cell.
  # A cell is a sample of storage-data selected for proving.
  CellSize* = 2048.uint64

type
  Cell* = seq[byte]
  ProofSample* = ref object
    cellData*: Cell
    slotBlockIndex*: uint64
    cellBlockProof*: Poseidon2Proof
    blockCellIndex*: uint64
    blockSlotProof*: Poseidon2Proof
  ProofInput* = ref object
    datasetRoot*: Poseidon2Hash
    entropy*: Poseidon2Hash
    numberOfCellsInSlot*: uint64
    numberOfSlots*: uint64
    datasetSlotIndex*: uint64
    slotRoot*: Poseidon2Hash
    datasetToSlotProof*: Poseidon2Proof
    proofSamples*: seq[ProofSample]
