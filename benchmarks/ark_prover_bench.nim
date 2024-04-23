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

proc createCircuits() =
  let cmds = """
    ${NIMCLI_DIR}/cli $CLI_ARGS -v --circom=${CIRCUIT_MAIN}.circom --output=input.json
    circom --r1cs --wasm --O2 -l${CIRCUIT_DIR} ${CIRCUIT_MAIN}.circom
    NODE_OPTIONS="--max-old-space-size=8192" snarkjs groth16 setup ${CIRCUIT_MAIN}.r1cs $PTAU_PATH ${CIRCUIT_MAIN}_0000.zkey
    echo "some_entropy_75289v3b7rcawcsyiur" | NODE_OPTIONS="--max-old-space-size=8192" snarkjs zkey contribute ${CIRCUIT_MAIN}_0000.zkey ${CIRCUIT_MAIN}_0001.zkey --name="1st Contributor Name"
    """.splitLines()

    # rm ${CIRCUIT_MAIN}_0000.zkey
    # mv ${CIRCUIT_MAIN}_0001.zkey ${CIRCUIT_MAIN}.zkey


proc setup() =
  let
    inputData = readFile("tests/circuits/fixtures/input.json")
    inputJson: JsonNode = !JsonNode.parse(inputData)
    proofInput: ProofInputs[Poseidon2Hash] =
      Poseidon2Hash.jsonToProofInput(inputJson)

  let
    datasetProof = Poseidon2Proof.init(
                    proofInput.slotIndex,
                    proofInput.nSlotsPerDataSet,
                    proofInput.slotProof[0..<4]).tryGet

  let ver = datasetProof.verify(proofInput.slotRoot, proofInput.datasetRoot).tryGet
  echo "ver: ", ver

setup()