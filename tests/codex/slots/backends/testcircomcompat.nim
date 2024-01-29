
import std/json
import std/sequtils
import std/sugar
import std/options

import pkg/chronos
import pkg/unittest2
import pkg/poseidon2

import pkg/codex/slots {.all.}
import pkg/codex/slots/types {.all.}
import pkg/codex/merkletree

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/constantine/math/io/io_bigints

import ./helpers

# privateAccess(CircomCompat)

suite "Test Backend":
  let
    r1cs = "tests/circuits/fixtures/proof_main.r1cs"
    wasm = "tests/circuits/fixtures/proof_main.wasm"

  var
    circom: CircomCompat
    verifyingKeyPtr: ptr CircomKey
    proofInput: ProofInput[Poseidon2Hash]
    publicInputs: CircomInputs

  setup:
    let
      inputData = readFile("tests/circuits/fixtures/input.json")
      inputJson = parseJson(inputData)
      jsonInputs = inputJson.jsonToInputData()

    proofInput = toProofInput[Poseidon2Hash](jsonInputs)
    publicInputs = jsonInputs.toPublicInputs.toCircomInputs

    # circom = CircomCompat.init(r1cs, wasm, zkey)
    circom = CircomCompat.init(r1cs, wasm)
    verifyingKeyPtr = circom.getVerifyingKey().tryGet

  teardown:
    publicInputs.relaseNimCircomInputs() # this is allocated by nim
    verifyingKeyPtr.addr.releaseKey()    # this comes from the rust FFI
    circom.release()                     # this comes from the rust FFI

  test "Should verify with known input":
    let
      proof = circom.prove(proofInput).tryGet

    check circom.verify(proof, publicInputs, verifyingKeyPtr[]).tryGet

  test "Should not verify with wrong input":
    proofInput.slotIndex = 1 # change slot index

    let
      proof = circom.prove(proofInput).tryGet

    check circom.verify(proof, publicInputs, verifyingKeyPtr[]).tryGet == false
