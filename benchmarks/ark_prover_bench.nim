import std/sequtils
import std/strutils
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

import create_circuits

proc setup(
  circuitDir: string, name: string,
) =
  let
    inputData = readFile("tests/circuits/fixtures/input.json")
    inputJson: JsonNode = !JsonNode.parse(inputData)
    proofInput: ProofInputs[Poseidon2Hash] = Poseidon2Hash.jsonToProofInput(inputJson)

  let datasetProof = Poseidon2Proof.init(
    proofInput.slotIndex, proofInput.nSlotsPerDataSet, proofInput.slotProof[0 ..< 4]
  ).tryGet

  let ver = datasetProof.verify(proofInput.slotRoot, proofInput.datasetRoot).tryGet
  echo "ver: ", ver

when isMainModule:
  echo "Running benchmark"
  # setup()
  checkEnv()

  let args = CircArgs(
    depth: 32, # maximum depth of the slot tree 
    maxslots: 256, # maximum number of slots  
    cellsize: 2048, # cell size in bytes 
    blocksize: 65536, # block size in bytes 
    nsamples: 5, # number of samples to prove
    entropy: 1234567, # external randomness
    seed: 12345, # seed for creating fake data
    nslots: 11, # number of slots in the dataset
    index: 3, # which slot we prove (0..NSLOTS-1)
    ncells: 512, # number of cells in this slot
  )

  let benchenv = createCircuit(args)

  ## TODO: copy over testcircomcompat proving
  when false:
    let
      r1cs = "tests/circuits/fixtures/proof_main.r1cs"
      wasm = "tests/circuits/fixtures/proof_main.wasm"
      zkey = "tests/circuits/fixtures/proof_main.zkey"

    var
      circom: CircomCompat
      proofInputs: ProofInputs[Poseidon2Hash]

    let
      inputData = readFile("tests/circuits/fixtures/input.json")
      inputJson = !JsonNode.parse(inputData)
      proofInputs = Poseidon2Hash.jsonToProofInput(inputJson)
      circom = CircomCompat.init(r1cs, wasm, zkey)

    let proof = circom.prove(proofInputs).tryGet

    circom.verify(proof, proofInputs).tryGet
    circom.release()  # this comes from the rust FFI

