import pkg/poseidon2/types
import ../merkletree

type
  Cell* = seq[byte]
  ProofSample* = ref object
    cellData*: Cell
    slotBlockIndex*: uint64
    blockSlotProof*: Poseidon2Proof
    blockCellIndex*: uint64
    cellBlockProof*: Poseidon2Proof
  ProofInput* = ref object
    datasetRoot*: Poseidon2Hash
    entropy*: Poseidon2Hash
    numberOfCellsInSlot*: uint64
    numberOfSlots*: uint64
    datasetSlotIndex*: uint64
    slotRoot*: Poseidon2Hash
    datasetToSlotProof*: Poseidon2Proof
    proofSamples*: seq[ProofSample]
