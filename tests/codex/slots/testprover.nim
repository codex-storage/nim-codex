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
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()

  var
    datasetBlocks: seq[bt.Block]
    store: BlockStore
    manifest: Manifest
    protected: Manifest
    verifiable: Manifest
    sampler: Poseidon2Sampler

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()

    store = RepoStore.new(repoDs, metaDs)

    (manifest, protected, verifiable) =
        await createVerifiableManifest(
          store,
          numDatasetBlocks,
          ecK, ecM,
          blockSize,
          cellSize)

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

  test "Should sample and prove a slot":
    let
      r1cs = "tests/circuits/fixtures/proof_main.r1cs"
      wasm = "tests/circuits/fixtures/proof_main.wasm"

      taskpool = Taskpool.new(num_threads = 6)
      params = CircomCompatParams.init(r1cs, wasm)
      circomBackend = AsyncCircomCompat.init(params, taskpool)
      prover = Prover.new(store, circomBackend, samples)
      challenge = 1234567.toF.toBytes.toArray32
      (inputs, proof) = (await prover.prove(1, verifiable, challenge)).tryGet

    check:
      (await prover.verify(proof, inputs)).tryGet == true

  test "Should sample and prove a slot with another circom":
    let
      r1cs = "tests/circuits/fixtures/proof_main.r1cs"
      wasm = "tests/circuits/fixtures/proof_main.wasm"

      taskpool = Taskpool.new(num_threads = 2)
      params = CircomCompatParams.init(r1cs, wasm)
      circomBackend = AsyncCircomCompat.init(params, taskpool)
      prover = Prover.new(store, circomBackend, samples)
      challenge = 1234567.toF.toBytes.toArray32
      (inputs, proof) = (await prover.prove(1, verifiable, challenge)).tryGet

    let
      taskpool2 = Taskpool.new(num_threads = 2)
      circomVerifyBackend = circomBackend.duplicate()
      proverVerify = Prover.new(store, circomVerifyBackend, samples)
    check:
      (await proverVerify.verify(proof, inputs)).tryGet == true

  test "Should sample and prove many slot":
    let
      r1cs = "tests/circuits/fixtures/proof_main.r1cs"
      wasm = "tests/circuits/fixtures/proof_main.wasm"

      taskpool = Taskpool.new(num_threads = 5)
      params = CircomCompatParams.init(r1cs, wasm)
      circomBackend = AsyncCircomCompat.init(params, taskpool)
      prover = Prover.new(store, circomBackend, samples)

    var proofs = newSeq[Future[?!(AnyProofInputs, AnyProof)]]()
    for i in 1..50:
      echo "PROVE: ", i
      let
        challenge = (1234567).toF.toBytes.toArray32

      proofs.add(prover.prove(1, verifiable, challenge))

    await allFutures(proofs)

    for pf in proofs:
      let (inputs, proof) = (await pf).tryGet
      check:
          (await prover.verify(proof, inputs)).tryGet == true
