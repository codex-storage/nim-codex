import std/sequtils
import std/options
import std/importutils

import ../../../asynctest

import pkg/questionable/results
import pkg/datastore
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints
import pkg/constantine/math/io/io_fields

import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/merkletree
import pkg/codex/utils/json
import pkg/codex/codextypes
import pkg/codex/slots/sampler
import pkg/codex/slots/builder
import pkg/codex/utils/poseidon2digest
import pkg/codex/slots/sampler/utils

import ../backends/helpers
import ../helpers
import ../../helpers

suite "Test control inputs":

  test "Should verify control inputs":
    let
      inputData = readFile("tests/circuits/fixtures/input.json")
      inputJson = parseJson(inputData)
      proofInput = jsonToProofInput[Poseidon2Hash](inputJson)

    let
      blockCells = 32
      cellIdxs = proofInput.entropy.cellIndices(proofInput.slotRoot, proofInput.nCellsPerSlot, 5)

    for i, cellIdx in cellIdxs:
      let
        sample = proofInput.samples[i]
        cellIdx = cellIdxs[i]

        cellProof = Poseidon2Proof.init(
          cellIdx.toCellInBlk(blockCells),
          proofInput.nCellsPerSlot,
          sample.merklePaths[0..<5]).tryGet

        slotProof = Poseidon2Proof.init(
          cellIdx.toBlkInSlot(blockCells),
          proofInput.nCellsPerSlot,
          sample.merklePaths[5..<9]).tryGet

        cellData =
          block:
            var
              pos = 0
              cellElms: seq[Bn254Fr]
            while pos < sample.cellData.len:
              var
                step = 32
                offset = min(pos + step, sample.cellData.len)
                data = sample.cellData[pos..<offset]
              let ff = Bn254Fr.fromBytes(data.toArray32).get
              cellElms.add(ff)
              pos += data.len

            cellElms

        cellLeaf = Poseidon2Hash.spongeDigest(cellData, rate = 2).tryGet
        slotLeaf = cellProof.reconstructRoot(cellLeaf).tryGet

      check slotProof.verify(slotLeaf, proofInput.slotRoot).tryGet

suite "Test sampler inputs":

  test "Should verify sampler inputs":
    let
      cellIndex = 1
      nSamples = 5
      blockSize = DefaultBlockSize
      cellSize = DefaultCellSize
      ecK = 2
      ecM = 2

      numSlots = ecK + ecM
      numDatasetBlocks = 8
      numTotalBlocks = calcEcBlocksCount(numDatasetBlocks, ecK, ecM)  # total number of blocks in the dataset after
                                                                      # EC (should will match number of slots)
      originalDatasetSize = numDatasetBlocks * blockSize.int
      totalDatasetSize    = numTotalBlocks * blockSize.int

      repoDs = SQLiteDatastore.new(Memory).tryGet()
      metaDs = SQLiteDatastore.new(Memory).tryGet()

      store = RepoStore.new(repoDs, metaDs)
      chunker = RandomChunker.new(Rng.instance(), size = totalDatasetSize, chunkSize = blockSize)
      datasetBlocks = await chunker.createBlocks(store)

      (manifest, protectedManifest) =
          await createProtectedManifest(
            datasetBlocks,
            store,
            numDatasetBlocks,
            ecK, ecM,
            blockSize,
            originalDatasetSize,
            totalDatasetSize)

      # build slots from protected manifest
      builder = Poseidon2Builder.new(store, protectedManifest, cellSize = cellSize).tryGet
      verifiableManifest = (await builder.buildManifest()).tryGet

      # create sampler
      verifiableBuilder = Poseidon2Builder.new(store, verifiableManifest).tryGet
      sampler = Poseidon2Sampler.new(cellIndex, store, verifiableBuilder).tryGet

      entropy = 1234567.toF

      verifyTree = verifiableBuilder.verifyTree.get           # get the dataset tree
      slotProof = verifyTree.getProof(cellIndex).tryGet       # get slot proof for index
      datasetRoot = verifyTree.root().tryGet                  # get dataset root
      slotTreeCid = verifiableManifest.slotRoots[cellIndex]   # get slot tree cid to retrieve proof from storage
      slotRoot = verifiableBuilder.slotRoots[cellIndex]       # get slot root hash
      cellIdxs = entropy.cellIndices(
        slotRoot,
        verifiableBuilder.numSlotCells,
        nSamples)

      nBlockCells = verifiableBuilder.numBlockCells
      nSlotCells = verifiableBuilder.numSlotCells

    for i, cellIdx in cellIdxs:
      let
        sample = (await sampler.getSample(cellIdx, slotTreeCid, slotRoot)).tryGet

        cellProof = Poseidon2Proof.init(
          cellIdx.toCellInBlk(nBlockCells),
          nSlotCells,
          sample.merklePaths[0..<5]).tryGet

        slotProof = Poseidon2Proof.init(
          cellIdx.toBlkInSlot(nBlockCells),
          nSlotCells,
          sample.merklePaths[5..<sample.merklePaths.len]).tryGet

        cellLeaf = Poseidon2Hash.spongeDigest(sample.cellData, rate = 2).tryGet
        slotLeaf = cellProof.reconstructRoot(cellLeaf).tryGet

      check slotProof.verify(slotLeaf, slotRoot).tryGet
