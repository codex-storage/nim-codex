import std/sequtils
import std/sugar
import std/math

import ../../asynctest

import pkg/taskpools
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

import ./helpers
import ../helpers
import ./backends/helpers

suite "Test Prover":
  let
    slotId = 1
    samples = 5
    ecK = 3
    ecM = 2
    numDatasetBlocks = 8
    blockSize = DefaultBlockSize
    cellSize = DefaultCellSize

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

      taskpool = Taskpool.new(num_threads = 2)
      params = CircomCompatParams.init(r1cs, wasm)
      circomBackend = AsyncCircomCompat.init(params, taskpool)
      prover = Prover.new(store, circomBackend, samples)
      challenge = 1234567.toF.toBytes.toArray32
      (inputs, proof) = (await prover.prove(1, verifiable, challenge)).tryGet
      # res = (await prover.prove(1, verifiable, challenge))
    echo "TEST PROOF: result: ", proof
    echo "TEST PROOF: state: ", params
    check:
      (await prover.verify(proof, inputs)).tryGet == true

  test "Should sample and prove many slot":
    let
      r1cs = "tests/circuits/fixtures/proof_main.r1cs"
      wasm = "tests/circuits/fixtures/proof_main.wasm"


      taskpool = Taskpool.new(num_threads = 8)
      params = CircomCompatParams.init(r1cs, wasm)
      circomBackend = AsyncCircomCompat.init(params, taskpool)
      prover = Prover.new(store, circomBackend, samples)

    var proofs = newSeq[Future[?!(AnyProofInputs, AnyProof)]]()
    for i in 1..20:
      echo "PROVE: ", i
      let
        challenge = (1234567).toF.toBytes.toArray32

      proofs.add(prover.prove(1, verifiable, challenge))

    await allFutures(proofs)
    echo "done"

    for pf in proofs:
      let (inputs, proof) = (await pf).tryGet
      check:
          (await prover.verify(proof, inputs)).tryGet == true
    echo "done done"
