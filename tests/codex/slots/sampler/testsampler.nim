import std/[sequtils, options, math]

import ../../../asynctest

import pkg/taskpools
import pkg/questionable/results

import pkg/codex/stores
import pkg/codex/erasure
import pkg/codex/merkletree
import pkg/codex/utils/json
import pkg/codex/codextypes
import pkg/codex/slots
import pkg/codex/slots/builder
import pkg/codex/utils/poseidon2digest
import pkg/codex/slots/sampler/utils

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints

import ../backends/helpers
import ../helpers
import ../../helpers

suite "Test Sampler - control samples":
  var
    inputData: string
    inputJson: JsonNode
    proofInput: ProofInputs[Poseidon2Hash]

  setup:
    inputData = readFile("tests/circuits/fixtures/input.json")
    inputJson = !JsonNode.parse(inputData)
    proofInput = Poseidon2Hash.jsonToProofInput(inputJson)

  test "Should verify control samples":
    let
      blockCells = 32
      cellIdxs =
        proofInput.entropy.cellIndices(proofInput.slotRoot, proofInput.nCellsPerSlot, 5)

    for i, cellIdx in cellIdxs:
      let
        sample = proofInput.samples[i]
        cellIdx = cellIdxs[i]

        cellProof = Poseidon2Proof.init(
          cellIdx.toCellInBlk(blockCells),
          proofInput.nCellsPerSlot,
          sample.merklePaths[0 ..< 5],
        ).tryGet

        slotProof = Poseidon2Proof.init(
          cellIdx.toBlkInSlot(blockCells),
          proofInput.nCellsPerSlot,
          sample.merklePaths[5 ..< 9],
        ).tryGet

        cellData = sample.cellData
        cellLeaf = Poseidon2Hash.spongeDigest(cellData, rate = 2).tryGet
        slotLeaf = cellProof.reconstructRoot(cellLeaf).tryGet

      check slotProof.verify(slotLeaf, proofInput.slotRoot).tryGet

  test "Should verify control dataset root":
    let datasetProof = Poseidon2Proof.init(
      proofInput.slotIndex, proofInput.nSlotsPerDataSet, proofInput.slotProof[0 ..< 4]
    ).tryGet

    check datasetProof.verify(proofInput.slotRoot, proofInput.datasetRoot).tryGet

suite "Test Sampler":
  let
    slotIndex = 3
    nSamples = 5
    ecK = 3
    ecM = 2
    datasetBlocks = 8
    entropy = 1234567.toF
    blockSize = DefaultBlockSize
    cellSize = DefaultCellSize
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()

  var
    store: RepoStore
    builder: Poseidon2Builder
    manifest: Manifest
    protected: Manifest
    verifiable: Manifest
    taskpool: Taskpool
    erasure: Erasure

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()

    store = RepoStore.new(repoDs, metaDs)
    taskpool = Taskpool.new()
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider, taskpool)

    (manifest, protected, verifiable) = await createVerifiableManifest(
      store, datasetBlocks, ecK, ecM, blockSize, cellSize, erasure
    )

    # create sampler
    builder = Poseidon2Builder.new(store, verifiable, erasure).tryGet

  teardown:
    await store.close()
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

    if not taskpool.isNil:
      taskpool.shutdown()

    reset(taskpool)

  test "Should fail instantiating for invalid slot index":
    let sampler = Poseidon2Sampler.new(builder.slotRoots.len, store, builder)

    check sampler.isErr

  test "Should fail instantiating for non verifiable builder":
    let
      nonVerifiableBuilder = Poseidon2Builder.new(store, protected, erasure).tryGet
      sampler = Poseidon2Sampler.new(slotIndex, store, nonVerifiableBuilder)

    check sampler.isErr

  test "Should verify samples":
    let
      sampler = Poseidon2Sampler.new(slotIndex, store, builder).tryGet

      verifyTree = builder.verifyTree.get # get the dataset tree
      slotProof = verifyTree.getProof(slotIndex).tryGet # get slot proof for index
      datasetRoot = verifyTree.root().tryGet # get dataset root
      slotTreeCid = verifiable.slotRoots[slotIndex]
        # get slot tree cid to retrieve proof from storage
      slotRoot = builder.slotRoots[slotIndex] # get slot root hash
      nSlotCellsEncoded = builder.numSlotCellsEncoded
      pow2SlotCellsEncoded = nextPowerOfTwo(nSlotCellsEncoded)
      cellIdxs = entropy.cellIndices(slotRoot, pow2SlotCellsEncoded, nSamples)
      nBlockCells = builder.numBlockCells

    for i, cellIdx in cellIdxs:
      let
        sample = (await sampler.getSample(cellIdx, slotTreeCid, slotRoot)).tryGet

        cellProof = Poseidon2Proof.init(
          cellIdx.toCellInBlk(nBlockCells),
          nSlotCellsEncoded,
          sample.merklePaths[0 ..< 5],
        ).tryGet

        slotProof = Poseidon2Proof.init(
          cellIdx.toBlkInSlot(nBlockCells),
          nSlotCellsEncoded,
          sample.merklePaths[5 ..< sample.merklePaths.len],
        ).tryGet

        cellData = sample.cellData
        cellLeaf = Poseidon2Hash.spongeDigest(cellData, rate = 2).tryGet
        slotLeaf = cellProof.reconstructRoot(cellLeaf).tryGet

      check slotProof.verify(slotLeaf, slotRoot).tryGet

  test "Should verify dataset root":
    let
      sampler = Poseidon2Sampler.new(slotIndex, store, builder).tryGet
      proofInput =
        (await sampler.getProofInput(entropy.toBytes.toArray32, nSamples)).tryGet

      datasetProof = Poseidon2Proof.init(
        proofInput.slotIndex, builder.slotRoots.len, proofInput.slotProof
      ).tryGet

    check datasetProof.verify(builder.slotRoots[slotIndex], builder.verifyRoot.get).tryGet
