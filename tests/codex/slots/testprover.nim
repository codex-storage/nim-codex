import std/sequtils
import std/sugar

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

import ./helpers
import ../helpers
import ./backends/helpers

suite "Test Prover":
  let
    blockSize = NBytes 1024
    cellSize = NBytes 64
    ecK = 3
    ecM = 2

    numSlots = ecK + ecM
    numDatasetBlocks = 100
    numTotalBlocks = calcEcBlocksCount(numDatasetBlocks, ecK, ecM)  # total number of blocks in the dataset after
                                                                    # EC (should will match number of slots)
    originalDatasetSize = numDatasetBlocks * blockSize.int
    totalDatasetSize    = numTotalBlocks * blockSize.int

  var
    datasetBlocks: seq[bt.Block]
    store: BlockStore
    chunker: Chunker
    verifiableManifest: Manifest
    sampler: Poseidon2Sampler

  setup:
    let
      repoDs = SQLiteDatastore.new(Memory).tryGet()
      metaDs = SQLiteDatastore.new(Memory).tryGet()

    store = RepoStore.new(repoDs, metaDs)
    chunker = RandomChunker.new(Rng.instance(), size = totalDatasetSize, chunkSize = blockSize)
    datasetBlocks = await chunker.createBlocks(store)

    let
      (manifest, protectedManifest) =
          await createProtectedManifest(
            datasetBlocks,
            store,
            numDatasetBlocks,
            ecK, ecM,
            blockSize,
            originalDatasetSize,
            totalDatasetSize)

      builder = Poseidon2Builder.new(store, protectedManifest, cellSize = cellSize).tryGet

    # build the slots
    verifiableManifest = (await builder.buildManifest()).tryGet

  test "Should sample and prove a slot":
    let
      r1cs = "tests/circuits/fixtures/proof_main.r1cs"
      wasm = "tests/circuits/fixtures/proof_main.wasm"

      circomBackend = CircomCompat.init(r1cs, wasm)
      prover = Prover.new(store, circomBackend)
      challenge = 12345.toF.toBytes.toArray32
      proof = (await prover.prove(1, verifiableManifest, 5, challenge)).tryGet
      key = circomBackend.getVerifyingKey().tryGet
      builder = Poseidon2Builder.new(store, verifiableManifest).tryGet
      sampler = Poseidon2Sampler.new(1, store, builder).tryGet
      proofInput = (await sampler.getProofInput(challenge, 5)).tryGet
      inputs = toCircomInputs(PublicInputs(
        slotIndex: proofInput.slotIndex.toF,
        datasetRoot: proofInput.verifyRoot,
        entropy: proofInput.entropy
      ))

    check:
      (await prover.verify(proof, inputs, key[])).tryGet
