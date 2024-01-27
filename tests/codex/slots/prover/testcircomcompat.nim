
import std/json
import std/sequtils
import std/sugar
import std/options

import pkg/chronos
import pkg/unittest2
import pkg/poseidon2

import pkg/codex/slots
import pkg/codex/slots/types
import pkg/codex/merkletree

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/constantine/math/io/io_bigints

import ./helpers

suite "Test Backend":
  let
    r1cs = "tests/codex/slots/prover/fixtures/proof_main.r1cs"
    wasm = "tests/codex/slots/prover/fixtures/proof_main.wasm"

  var
    circom: CircomCompat
    proofInput: ProofInput[Poseidon2Hash]

  setup:
    let
      inputData = readFile("tests/codex/slots/prover/fixtures/input.json")
      inputJson = parseJson(inputData)

    proofInput = toProofInput[Poseidon2Hash](inputJson.toInput())

    # circom = CircomCompat.init(r1cs, wasm, zkey)
    circom = CircomCompat.init(r1cs, wasm)

  teardown:
    circom.release()

  test "Should verify with known input":
    let
      proof = circom.prove(proofInput).tryGet
    check circom.verify(proof).tryGet

    proof.release()

  test "Should not verify with wrong input":
    proofInput.slotIndex = 1 # change slot index

    let
      proof = circom.prove(proofInput).tryGet
    check circom.verify(proof).tryGet == false

    proof.release()
