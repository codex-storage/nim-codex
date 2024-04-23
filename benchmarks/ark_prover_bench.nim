import std/sequtils
import std/options
import std/importutils

import pkg/questionable
import pkg/questionable/results
import pkg/datastore

import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/merkletree
import pkg/codex/utils/json
import pkg/codex/codextypes
import pkg/codex/slots
import pkg/codex/slots/builder
import pkg/codex/utils/poseidon2digest
import pkg/codex/slots/sampler/utils

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints
import pkg/constantine/math/io/io_fields

import codex/slots/backends/helpers

var
  inputData: string
  inputJson: JsonNode
  proofInput: ProofInputs[Poseidon2Hash]

proc setup() =
  inputData = readFile("tests/circuits/fixtures/input.json")
  inputJson = !JsonNode.parse(inputData)
  proofInput = Poseidon2Hash.jsonToProofInput(inputJson)

  let
    blockCells = 32
    cellIdxs = proofInput.entropy.cellIndices(proofInput.slotRoot, proofInput.nCellsPerSlot, 5)

  for i, cellIdx in cellIdxs:
    let
      sample = proofInput.samples[i]
      cellIdx = cellIdxs[i]

      cellProof = Poseidon2Proof.init(
        cellIdx.toCellInBlk(blockCells),
        proofInput.nCellsPerSlot,
        sample.merklePaths[0..<5]).tryGet

      slotProof = Poseidon2Proof.init(
        cellIdx.toBlkInSlot(blockCells),
        proofInput.nCellsPerSlot,
        sample.merklePaths[5..<9]).tryGet

      cellData = Poseidon2Hash.fromCircomData(sample.cellData)
      cellLeaf = Poseidon2Hash.spongeDigest(cellData, rate = 2).tryGet
      slotLeaf = cellProof.reconstructRoot(cellLeaf).tryGet

    # check slotProof.verify(slotLeaf, proofInput.slotRoot).tryGet
