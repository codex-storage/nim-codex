
import std/sequtils
import std/sugar
import std/options

import pkg/chronos
import ../../../asynctest
import pkg/poseidon2
import pkg/datastore

import pkg/codex/slots {.all.}
import pkg/codex/slots/types {.all.}
import pkg/codex/merkletree
import pkg/codex/utils/json
import pkg/codex/codextypes
import pkg/codex/manifest
import pkg/codex/stores

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/constantine/math/io/io_bigints

import ./helpers
import ../helpers

suite "Test Circom Compat Backend - control input":
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

    proofInput = jsonToProofInput[Poseidon2Hash](inputJson)
    publicInputs = toPublicInputs[Poseidon2Hash](proofInput).toCircomInputs

    # circom = CircomCompat.init(r1cs, wasm, zkey)
    circom = CircomCompat.init(r1cs, wasm)
    verifyingKeyPtr = circom.getVerifyingKey().tryGet

  teardown:
    publicInputs.releaseNimInputs()      # this is allocated by nim
    verifyingKeyPtr.addr.releaseKey()    # this comes from the rust FFI
    circom.release()                     # this comes from the rust FFI

  test "Should verify with correct input":
    let
      proof = circom.prove(proofInput).tryGet

    check circom.verify(proof, publicInputs, verifyingKeyPtr[]).tryGet

  test "Should not verify with incorrect input":
    proofInput.slotIndex = 1 # change slot index

    let
      proof = circom.prove(proofInput).tryGet

    check circom.verify(proof, publicInputs, verifyingKeyPtr[]).tryGet == false

suite "Test Circom Compat Backend":
  let
    slotId = 3
    samples = 5
    blockSize = DefaultBlockSize
    cellSize = DefaultCellSize
    ecK = 2
    ecM = 2
    numDatasetBlocks = 8

    r1cs = "tests/circuits/fixtures/proof_main.r1cs"
    wasm = "tests/circuits/fixtures/proof_main.wasm"

  var
    store: BlockStore
    manifest: Manifest
    protected: Manifest
    verifiable: Manifest
    circom: CircomCompat
    verifyingKeyPtr: ptr CircomKey
    proofInput: ProofInput[Poseidon2Hash]
    publicInputs: CircomInputs
    challenge: array[32, byte]
    builder: Poseidon2Builder
    sampler: Poseidon2Sampler

  setup:
    let
      repoDs = SQLiteDatastore.new(Memory).tryGet()
      metaDs = SQLiteDatastore.new(Memory).tryGet()

    store = RepoStore.new(repoDs, metaDs)

    (manifest, protected, verifiable) =
        await createVerifiableManifest(
          store,
          numDatasetBlocks,
          ecK, ecM,
          blockSize,
          cellSize)

    builder = Poseidon2Builder.new(store, verifiable).tryGet
    sampler = Poseidon2Sampler.new(slotId, store, builder).tryGet

    # circom = CircomCompat.init(r1cs, wasm, zkey)
    circom = CircomCompat.init(r1cs, wasm)
    verifyingKeyPtr = circom.getVerifyingKey().tryGet
    challenge = 1234567.toF.toBytes.toArray32

    proofInput = (await sampler.getProofInput(challenge, samples)).tryGet
    publicInputs = proofInput.toPublicInputs.toCircomInputs

  teardown:
    publicInputs.releaseNimInputs()      # this is allocated by nim
    verifyingKeyPtr.addr.releaseKey()    # this comes from the rust FFI
    circom.release()                     # this comes from the rust FFI

  test "Should verify with correct input":
    var
      proof = circom.prove(proofInput).tryGet

    check circom.verify(proof, publicInputs, verifyingKeyPtr[]).tryGet

  test "Should not verify with incorrect input":
    proofInput.slotIndex = 1 # change slot index

    let
      proof = circom.prove(proofInput).tryGet

    check circom.verify(proof, publicInputs, verifyingKeyPtr[]).tryGet == false
