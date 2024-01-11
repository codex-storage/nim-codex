import std/sequtils
import std/math
import std/importutils
import std/sugar

import pkg/chronos
import pkg/asynctest
import pkg/questionable/results
import pkg/codex/blocktype as bt
import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/chunker
import pkg/codex/merkletree
import pkg/codex/manifest {.all.}
import pkg/codex/utils
import pkg/codex/utils/digest
import pkg/datastore
import pkg/poseidon2
import pkg/poseidon2/io
import constantine/math/io/io_fields

import ../helpers
import ../examples
import ../merkletree/helpers

import pkg/codex/indexingstrategy {.all.}
import pkg/codex/slots/builder {.all.}
import pkg/codex/slots/converters
import pkg/codex/slots {.all.}

privateAccess(SlotsBuilder) # enable access to private fields
privateAccess(Manifest) # enable access to private fields

suite "Slot builder":
  let
    blockSize = 1024
    cellSize = 64
    ecK = 3
    ecM = 2

    numSlots = ecK + ecM
    numDatasetBlocks = 100
    numBlockCells = blockSize div cellSize

    numTotalBlocks = calcEcBlocksCount(numDatasetBlocks, ecK, ecM)                # total number of blocks in the dataset after
                                                                                  # EC (should will match number of slots)
    originalDatasetSize = numDatasetBlocks * blockSize                            # size of the dataset before EC
    totalDatasetSize = numTotalBlocks * blockSize                                 # size of the dataset after EC
    numTotalSlotBlocks = nextPowerOfTwo(numTotalBlocks div numSlots)

    blockPadBytes =
      newSeq[byte](numBlockCells.nextPowerOfTwoPad * cellSize)                    # power of two padding for blocks

    slotsPadLeafs =
      newSeqWith((numTotalBlocks div numSlots).nextPowerOfTwoPad, Poseidon2Zero)  # power of two padding for block roots

    rootsPadLeafs =
      newSeqWith(numSlots.nextPowerOfTwoPad, Poseidon2Zero)

  var
    datasetBlocks: seq[bt.Block]
    localStore: BlockStore
    manifest: Manifest
    protectedManifest: Manifest
    expectedEmptyCid: Cid
    slotBuilder: SlotsBuilder
    chunker: Chunker

  proc createBlocks(): Future[void] {.async.} =
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break
      let blk = bt.Block.new(chunk).tryGet()
      datasetBlocks.add(blk)
      discard await localStore.putBlock(blk)

  proc createProtectedManifest(): Future[void] {.async.} =
    let
      cids = datasetBlocks.mapIt(it.cid)
      datasetTree = CodexTree.init(cids[0..<numDatasetBlocks]).tryGet()
      datasetTreeCid = datasetTree.rootCid().tryGet()

      protectedTree = CodexTree.init(cids).tryGet()
      protectedTreeCid = protectedTree.rootCid().tryGet()

    for index, cid in cids[0..<numDatasetBlocks]:
      let proof = datasetTree.getProof(index).tryget()
      (await localStore.putCidAndProof(datasetTreeCid, index, cid, proof)).tryGet

    for index, cid in cids:
      let proof = protectedTree.getProof(index).tryget()
      (await localStore.putCidAndProof(protectedTreeCid, index, cid, proof)).tryGet

    manifest = Manifest.new(
      treeCid = datasetTreeCid,
      blockSize = blockSize.NBytes,
      datasetSize = originalDatasetSize.NBytes)

    protectedManifest = Manifest.new(
      manifest = manifest,
      treeCid = protectedTreeCid,
      datasetSize = totalDatasetSize.NBytes,
      ecK = ecK,
      ecM = ecM)

    let
      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec).tryGet()

      protectedManifestBlock = bt.Block.new(
        protectedManifest.encode().tryGet(),
        codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()
    (await localStore.putBlock(protectedManifestBlock)).tryGet()

    expectedEmptyCid = emptyCid(
      protectedManifest.version,
      protectedManifest.hcodec,
      protectedManifest.codec).tryGet()

  setup:
    let
      repoDs = SQLiteDatastore.new(Memory).tryGet()
      metaDs = SQLiteDatastore.new(Memory).tryGet()
    localStore = RepoStore.new(repoDs, metaDs)

    chunker = RandomChunker.new(Rng.instance(), size = totalDatasetSize, chunkSize = blockSize)
    await createBlocks()
    await createProtectedManifest()

  teardown:
    await localStore.close()

    # TODO: THIS IS A BUG IN asynctest, because it doesn't release the
    #       objects after the test is done, so we need to do it manually
    #
    # Need to reset all objects because otherwise they get
    # captured by the test runner closures, not good!
    reset(datasetBlocks)
    reset(localStore)
    reset(manifest)
    reset(protectedManifest)
    reset(expectedEmptyCid)
    reset(slotBuilder)
    reset(chunker)

  test "Can only create slotBuilder with protected manifest":
    let
      unprotectedManifest = Manifest.new(
        treeCid = Cid.example,
        blockSize = blockSize.NBytes,
        datasetSize = originalDatasetSize.NBytes)

    check:
      SlotsBuilder.new(localStore, unprotectedManifest, cellSize = cellSize)
        .error.msg == "Can only create SlotsBuilder using protected manifests."

  test "Number of blocks must be devisable by number of slots":
    let
      mismatchManifest = Manifest.new(
        manifest = Manifest.new(
          treeCid = Cid.example,
          blockSize = blockSize.NBytes,
          datasetSize = originalDatasetSize.NBytes),
        treeCid = Cid.example,
        datasetSize = totalDatasetSize.NBytes,
        ecK = ecK - 1,
        ecM = ecM)

    check:
      SlotsBuilder.new(localStore, mismatchManifest, cellSize = cellSize)
        .error.msg == "Number of blocks must be divisable by number of slots."

  test "Block size must be divisable by cell size":
    let
      mismatchManifest = Manifest.new(
        manifest = Manifest.new(
          treeCid = Cid.example,
          blockSize = (blockSize + 1).NBytes,
          datasetSize = (originalDatasetSize - 1).NBytes),
        treeCid = Cid.example,
        datasetSize = (totalDatasetSize - 1).NBytes,
        ecK = ecK,
        ecM = ecM)

    check:
      SlotsBuilder.new(localStore, mismatchManifest, cellSize = cellSize)
        .error.msg == "Block size must be divisable by cell size."

  test "Should build correct slot builder":
    slotBuilder = SlotsBuilder.new(
      localStore,
      protectedManifest,
      cellSize = cellSize).tryGet()

    check:
      slotBuilder.numBlockPadBytes == blockPadBytes.len
      slotBuilder.numSlotsPadLeafs == slotsPadLeafs.len
      slotBuilder.numRootsPadLeafs == rootsPadLeafs.len

  test "Should build slot hashes for all slots":
    let
      steppedStrategy = SteppedIndexingStrategy.new(0, numTotalBlocks - 1, numSlots)
      slotBuilder = SlotsBuilder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

    for i in 0 ..< numSlots:
      let
        expectedBlock = steppedStrategy
          .getIndicies(i)
          .mapIt( datasetBlocks[it] )

        expectedHashes: seq[Poseidon2Hash] = collect(newSeq):
          for blk in expectedBlock:
            SpongeMerkle.digest(blk.data & blockPadBytes, cellSize)

        cellHashes = (await slotBuilder.getCellHashes(i)).tryGet()

      check:
        expectedHashes == cellHashes

  test "Should build slot trees for all slots":
    let
      steppedStrategy = SteppedIndexingStrategy.new(0, numTotalBlocks - 1, numSlots)
      slotBuilder = SlotsBuilder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

    for i in 0 ..< numSlots:
      let
        expectedBlock = steppedStrategy
          .getIndicies(i)
          .mapIt( datasetBlocks[it] )

        expectedHashes: seq[Poseidon2Hash] = collect(newSeq):
          for blk in expectedBlock:
            SpongeMerkle.digest(blk.data & blockPadBytes, cellSize)
        expectedRoot = Merkle.digest(expectedHashes & slotsPadLeafs)

        slotTree = (await slotBuilder.buildSlotTree(i)).tryGet()

      check:
        expectedRoot == slotTree.root().tryGet()

  test "Should persist trees for all slots":
    let
      slotBuilder = SlotsBuilder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

    for i in 0 ..< numSlots:
      let
        slotTree = (await slotBuilder.buildSlotTree(i)).tryGet()
        slotRoot = (await slotBuilder.buildSlot(i)).tryGet()
        slotCid = slotRoot.toSlotCid().tryGet()

      for cellIndex in 0..<numTotalSlotBlocks:
        let
          (cellCid, proof) = (await localStore.getCidAndProof(slotCid, cellIndex)).tryGet()
          verifiableProof = proof.toVerifiableProof().tryGet()
          posProof = slotTree.getProof(cellIndex).tryGet

        check:
          verifiableProof.index == posProof.index
          verifiableProof.nleaves == posProof.nleaves
          verifiableProof.path == posProof.path

  test "Should build correct verification root":
    let
      steppedStrategy = SteppedIndexingStrategy.new(0, numTotalBlocks - 1, numSlots)
      slotBuilder = SlotsBuilder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

    (await slotBuilder.buildSlots()).tryGet
    let
      slotsHashes = collect(newSeq):
        for i in 0 ..< numSlots:
          let
            expectedBlocks = steppedStrategy
              .getIndicies(i)
              .mapIt( datasetBlocks[it] )

            slotHashes: seq[Poseidon2Hash] = collect(newSeq):
              for blk in expectedBlocks:
                SpongeMerkle.digest(blk.data & blockPadBytes, cellSize)

          Merkle.digest(slotHashes & slotsPadLeafs)

      expectedRoot = Merkle.digest(slotsHashes & rootsPadLeafs)
      rootHash = slotBuilder.buildRootsTree(slotBuilder.slotRoots).tryGet().root.tryGet()

    check:
      expectedRoot == rootHash

  test "Should build correct verification root manifest":
    let
      steppedStrategy = SteppedIndexingStrategy.new(0, numTotalBlocks - 1, numSlots)
      slotBuilder = SlotsBuilder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

      slotsHashes = collect(newSeq):
        for i in 0 ..< numSlots:
          let
            expectedBlocks = steppedStrategy
              .getIndicies(i)
              .mapIt( datasetBlocks[it] )

            slotHashes: seq[Poseidon2Hash] = collect(newSeq):
              for blk in expectedBlocks:
                SpongeMerkle.digest(blk.data & blockPadBytes, cellSize)

          Merkle.digest(slotHashes & slotsPadLeafs)

      expectedRoot = Merkle.digest(slotsHashes & rootsPadLeafs)
      manifest = (await slotBuilder.buildManifest()).tryGet()
      mhash = manifest.slotsRoot.mhash.tryGet()
      mhashBytes = mhash.digestBytes
      rootHash = Poseidon2Hash.fromBytes(mhashBytes.toArray32).get

    check:
      expectedRoot == rootHash

  test "Should not build from verifiable manifest with 0 slots":
    var
      slotBuilder = SlotsBuilder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()
      verificationManifest = (await slotBuilder.buildManifest()).tryGet()

    verificationManifest.slotRoots = @[]
    check SlotsBuilder.new(
        localStore,
        verificationManifest,
        cellSize = cellSize).isErr

  test "Should not build from verifiable manifest with incorrect number of slots":
    var
      slotBuilder = SlotsBuilder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

      verificationManifest = (await slotBuilder.buildManifest()).tryGet()

    verificationManifest.slotRoots.del(
      verificationManifest.slotRoots.len - 1
    )

    check SlotsBuilder.new(
        localStore,
        verificationManifest,
        cellSize = cellSize).isErr

  test "Should not build from verifiable manifest with slots root":
    let
      slotBuilder = SlotsBuilder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

      verificationManifest = (await slotBuilder.buildManifest()).tryGet()
      offset = verificationManifest.slotsRoot.data.buffer.len div 2

    rng.shuffle(
      Rng.instance,
      verificationManifest.slotsRoot.data.buffer)

    check SlotsBuilder.new(
        localStore,
        verificationManifest,
        cellSize = cellSize).isErr

  test "Should build from verifiable manifest":
    let
      slotBuilder = SlotsBuilder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

      verificationManifest = (await slotBuilder.buildManifest()).tryGet()

      verificationBuilder = SlotsBuilder.new(
        localStore,
        verificationManifest,
        cellSize = cellSize).tryGet()

    check:
      slotBuilder.slotRoots == verificationBuilder.slotRoots
      slotBuilder.slotsRoot == verificationBuilder.slotsRoot
