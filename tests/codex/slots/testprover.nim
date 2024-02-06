import std/sequtils
import std/sugar
import std/math

import ../../asynctest

import pkg/chronos
import pkg/libp2p/cid
import pkg/datastore

import pkg/codex/merkletree
import pkg/codex/rng
import pkg/codex/manifest
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/slots
import pkg/codex/stores
import pkg/poseidon2/io
import pkg/codex/utils/poseidon2digest

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints
import pkg/constantine/math/io/io_fields

import ./helpers
import ../helpers
import ./backends/helpers

suite "Test Prover":
  let
    slotId = 1
    samples = 5
    blockSize = DefaultBlockSize
    cellSize = DefaultCellSize
    ecK = 2
    ecM = 2
    numDatasetBlocks = 8

  var
    datasetBlocks: seq[bt.Block]
    store: BlockStore
    manifest: Manifest
    protected: Manifest
    verifiable: Manifest
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

  test "Should sample and prove a slot":
    let
      r1cs = "tests/circuits/fixtures/proof_main.r1cs"
      wasm = "tests/circuits/fixtures/proof_main.wasm"

      circomBackend = CircomCompat.init(r1cs, wasm)
      prover = Prover.new(store, circomBackend)
      challenge = 1234567.toF.toBytes.toArray32
      proof = (await prover.prove(1, verifiable, challenge, 5)).tryGet
      key = circomBackend.getVerifyingKey().tryGet
      builder = Poseidon2Builder.new(store, verifiable).tryGet
      sampler = Poseidon2Sampler.new(1, store, builder).tryGet
      proofInput = (await sampler.getProofInput(challenge, 5)).tryGet
      inputs = proofInput.toPublicInputs.toCircomInputs

    check:
      (await prover.verify(proof, inputs, key[])).tryGet == true
