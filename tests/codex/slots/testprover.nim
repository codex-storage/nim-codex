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
import pkg/codex/conf
import pkg/confutils/defs
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
      prover = Prover.new(store, samples)
      challenge = 1234567.toF.toBytes.toArray32
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: ValidIpAddress.init("127.0.0.1"),
        discoveryIp: ValidIpAddress.init(IPv4_any()),
        metricsAddress: ValidIpAddress.init("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        circomR1cs: InputFile("tests/circuits/fixtures/proof_main.r1cs"),
        circomWasm: InputFile("tests/circuits/fixtures/proof_main.wasm"),
        circomZkey: InputFile("tests/circuits/fixtures/proof_main.zkey")
      )
      ceremonyHash = string.none

    (await prover.start(config, ceremonyHash)).tryGet()

    let (inputs, proof) = (await prover.prove(1, verifiable, challenge)).tryGet

    check:
      (await prover.verify(proof, inputs)).tryGet == true
