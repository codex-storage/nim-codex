import pkg/poseidon2/types
import ../merkletree

const
  # Size of a cell.
  # A cell is a sample of storage-data selected for proving.
  CellSize* = 2048.uint64

type
  DSFieldElement* = F
  DSSlotCellIndex* = uint64
  DSCell* = seq[byte]
  ProofInput* = ref object
    datasetToSlotProof*: MerkleProof
    slotToBlockProofs*: seq[MerkleProof]
    blockToCellProofs*: seq[MerkleProof]
    sampleData*: seq[byte]
