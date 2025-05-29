import ../../asynctest

import pkg/chronos
import pkg/libp2p/cid

import pkg/codex/merkletree
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/slots
import pkg/codex/stores
import pkg/codex/conf
import pkg/confutils/defs
import pkg/poseidon2/io
import pkg/codex/utils/poseidon2digest
import pkg/codex/nat
import pkg/taskpools
import pkg/codex/utils/natutils
import ./helpers
import ../helpers

suite "Test CircomCompat Prover":
  let
    samples = 5
    blockSize = DefaultBlockSize
    cellSize = DefaultCellSize
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()
    tp = Taskpool.new()
    challenge = 1234567.toF.toBytes.toArray32

  var
    store: BlockStore
    prover: Prover

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()
      backend = CircomCompatBackendRef.new(
        r1csPath = "tests/circuits/fixtures/proof_main.r1cs",
        wasmPath = "tests/circuits/fixtures/proof_main.wasm",
        zkeyPath = "tests/circuits/fixtures/proof_main.zkey",
      ).tryGet
      tp = Taskpool.new()

    store = RepoStore.new(repoDs, metaDs)
    prover = Prover.new(backend, samples, tp)

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

  test "Should sample and prove a slot":
    let
      (_, _, verifiable) = await createVerifiableManifest(
        store,
        8, # number of blocks in the original dataset (before EC)
        5, # ecK
        3, # ecM
        blockSize,
        cellSize,
      )

      builder =
        Poseidon2Builder.new(store, verifiable, verifiable.verifiableStrategy).tryGet
      sampler = Poseidon2Sampler.new(1, store, builder).tryGet
      (_, checked) =
        (await prover.prove(sampler, verifiable, challenge, verify = true)).tryGet

    check:
      checked.isSome and checked.get == true

  test "Should generate valid proofs when slots consist of single blocks":
    # To get single-block slots, we just need to set the number of blocks in
    # the original dataset to be the same as ecK. The total number of blocks
    # after generating random data for parity will be ecK + ecM, which will
    # match the number of slots.
    let
      (_, _, verifiable) = await createVerifiableManifest(
        store,
        2, # number of blocks in the original dataset (before EC)
        2, # ecK
        1, # ecM
        blockSize,
        cellSize,
      )

      builder =
        Poseidon2Builder.new(store, verifiable, verifiable.verifiableStrategy).tryGet
      sampler = Poseidon2Sampler.new(1, store, builder).tryGet
      (_, checked) =
        (await prover.prove(sampler, verifiable, challenge, verify = true)).tryGet

    check:
      checked.isSome and checked.get == true
