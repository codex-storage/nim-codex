import pkg/poseidon2/types
import ../merkletree

const
  # Size of a cell.
  # A cell is a sample of storage-data selected for proving.
  CellSize* = 2048.uint64

type
  FieldElement* = F
  Cell* = seq[byte]
  ProofInput* = ref object
    datasetToSlotProof*: MerkleProof
    slotToBlockProofs*: seq[MerkleProof]
    blockToCellProofs*: seq[MerkleProof]
    sampleData*: seq[byte]
