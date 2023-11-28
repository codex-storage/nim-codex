import std/sequtils
import std/sugar
import std/random

import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/poseidon2/types
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/asynctest
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore

import pkg/codex/proof/datasampler
import pkg/codex/proof/misc
import pkg/codex/proof/types

import ../helpers
import ../examples
import testdatasampler_expected

let
  bytesPerBlock = 64 * 1024
  challenge: FieldElement = toF(12345)
  datasetRootHash: FieldElement = toF(6789)

asyncchecksuite "Test proof datasampler - components":
  let
    numberOfSlotBlocks = 16
    slot = Slot(
      request: StorageRequest(
        ask: StorageAsk(
          slots: 10,
          slotSize: u256(bytesPerBlock * numberOfSlotBlocks),
        ),
        content: StorageContent(
          cid: $Cid.example
        )
      ),
      slotIndex: u256(3)
    )

  test "Number of cells is a power of two":
    # This is to check that the data used for testing is sane.
    proc isPow2(value: int): bool =
      let log2 = ceilingLog2(value)
      return (1 shl log2) == value

    let numberOfCells = getNumberOfCellsInSlot(slot).int

    check:
      isPow2(numberOfCells)

  test "Extract low bits":
    proc extract(value: uint64, nBits: int): uint64 =
      let big = toF(value).toBig()
      return extractLowBits(big, nBits)

    check:
      extract(0x88, 4) == 0x8.uint64
      extract(0x88, 7) == 0x8.uint64
      extract(0x9A, 5) == 0x1A.uint64
      extract(0x9A, 7) == 0x1A.uint64
      extract(0x1248, 10) == 0x248.uint64
      extract(0x1248, 12) == 0x248.uint64
      extract(0x1248306A560C9AC0.uint64, 10) == 0x2C0.uint64
      extract(0x1248306A560C9AC0.uint64, 12) == 0xAC0.uint64
      extract(0x1248306A560C9AC0.uint64, 50) == 0x306A560C9AC0.uint64
      extract(0x1248306A560C9AC0.uint64, 52) == 0x8306A560C9AC0.uint64

  test "Should calculate total number of cells in Slot":
    let
      slotSizeInBytes = (slot.request.ask.slotSize).truncate(uint64)
      expectedNumberOfCells = slotSizeInBytes div CellSize

    check:
      expectedNumberOfCells == 512
      expectedNumberOfCells == getNumberOfCellsInSlot(slot)

asyncchecksuite "Test proof datasampler - main":
  let
    # The number of slot blocks and number of slots, combined with
    # the bytes per block, make it so that there are exactly 256 cells
    # in the dataset.
    numberOfSlotBlocks = 4
    totalNumberOfSlots = 2
    datasetSlotIndex = 1
    localStore = CacheStore.new()
    datasetToSlotProof = MerkleProof.example

  var
    manifest: Manifest
    manifestBlock: bt.Block
    slot: Slot
    datasetBlocks: seq[bt.Block]
    slotPoseidonTree: MerkleTree
    dataSampler: DataSampler

  proc createDatasetBlocks(): Future[void] {.async.} =
    let numberOfCellsNeeded = (numberOfSlotBlocks * totalNumberOfSlots * bytesPerBlock).uint64 div CellSize
    var data: seq[byte] = @[]

    # This generates a number of blocks that have different data, such that
    # Each cell in each block is unique, but nothing is random.
    for i in 0 ..< numberOfCellsNeeded:
      data = data & (i.byte).repeat(CellSize)

    let chunker = MockChunker.new(
      dataset = data,
      chunkSize = bytesPerBlock)

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break
      let b = bt.Block.new(chunk).tryGet()
      datasetBlocks.add(b)
      discard await localStore.putBlock(b)

  proc createManifest(): Future[void] {.async.} =
    let
      cids = datasetBlocks.mapIt(it.cid)
      tree = MerkleTree.init(cids).tryGet()
      treeCid = tree.rootCid().tryGet()

    for index, cid in cids:
      let proof = tree.getProof(index).tryget()
      discard await localStore.putBlockCidAndProof(treeCid, index, cid, proof)

    manifest = Manifest.new(
      treeCid = treeCid,
      blockSize = bytesPerBlock.NBytes,
      datasetSize = (bytesPerBlock * numberOfSlotBlocks * totalNumberOfSlots).NBytes)
    manifestBlock = bt.Block.new(manifest.encode().tryGet(), codec = DagPBCodec).tryGet()

  proc createSlot(): void =
    slot = Slot(
      request: StorageRequest(
        ask: StorageAsk(
          slotSize: u256(bytesPerBlock * numberOfSlotBlocks)
        ),
        content: StorageContent(
          cid: $manifestBlock.cid
        ),
      ),
      slotIndex: u256(datasetSlotIndex)
    )

  proc createSlotPoseidonTree(): void =
    let
      slotSize = slot.request.ask.slotSize.truncate(uint64)
      blocksInSlot = slotSize div bytesPerBlock.uint64
      datasetSlotIndex = slot.slotIndex.truncate(uint64)
      datasetBlockIndexFirst = datasetSlotIndex * blocksInSlot
      datasetBlockIndexLast = datasetBlockIndexFirst + numberOfSlotBlocks.uint64
      slotBlocks = datasetBlocks[datasetBlockIndexFirst ..< datasetBlockIndexLast]
      slotBlockCids = slotBlocks.mapIt(it.cid)
    slotPoseidonTree = MerkleTree.init(slotBlockCids).tryGet()

  proc createDataSampler(): Future[void] {.async.} =
    dataSampler = (await DataSampler.new(
      slot,
      localStore,
      datasetRootHash,
      slotPoseidonTree,
      datasetToSlotProof
    )).tryGet()

  setup:
    await createDatasetBlocks()
    await createManifest()
    createSlot()
    discard await localStore.putBlock(manifestBlock)
    createSlotPoseidonTree()
    await createDataSampler()

  test "Number of cells is a power of two":
    # This is to check that the data used for testing is sane.
    proc isPow2(value: int): bool =
      let log2 = ceilingLog2(value)
      return (1 shl log2) == value

    let numberOfCells = getNumberOfCellsInSlot(slot).int

    check:
      isPow2(numberOfCells)

  let knownIndices = @[74.uint64, 41.uint64, 51.uint64]

  test "Can find single slot-cell index":
    proc slotCellIndex(i: int): uint64 =
      let counter: FieldElement = toF(i)
      return dataSampler.findSlotCellIndex(challenge, counter)

    proc getExpectedIndex(i: int): uint64 =
      let
        numberOfCellsInSlot = (bytesPerBlock * numberOfSlotBlocks) div CellSize.int
        slotRootHash = toF(1234) # TODO - replace with slotPoseidonTree.root when it is a poseidon tree.
        hash = Sponge.digest(@[slotRootHash, challenge, toF(i)], rate = 2)
      return extractLowBits(hash.toBig(), ceilingLog2(numberOfCellsInSlot))

    check:
      slotCellIndex(1) == getExpectedIndex(1)
      slotCellIndex(1) == knownIndices[0]
      slotCellIndex(2) == getExpectedIndex(2)
      slotCellIndex(2) == knownIndices[1]
      slotCellIndex(3) == getExpectedIndex(3)
      slotCellIndex(3) == knownIndices[2]

  test "Can find sequence of slot-cell indices":
    proc slotCellIndices(n: int): seq[uint64]  =
      dataSampler.findSlotCellIndices(challenge, n)

    proc getExpectedIndices(n: int): seq[uint64]  =
      return collect(newSeq, (for i in 1..n: dataSampler.findSlotCellIndex(challenge, toF(i))))

    check:
      slotCellIndices(3) == getExpectedIndices(3)
      slotCellIndices(3) == knownIndices

  let
    bytes = newSeqWith(bytesPerBlock, rand(uint8))
    blk = bt.Block.new(bytes).tryGet()
    cell0Bytes = bytes[0..<CellSize]
    cell1Bytes = bytes[CellSize..<(CellSize*2)]
    cell2Bytes = bytes[(CellSize*2)..<(CellSize*3)]

  test "Can get cell from block":
    let
      sample0 = dataSampler.getCellFromBlock(blk, 0)
      sample1 = dataSampler.getCellFromBlock(blk, 1)
      sample2 = dataSampler.getCellFromBlock(blk, 2)

    check:
      sample0 == cell0Bytes
      sample1 == cell1Bytes
      sample2 == cell2Bytes

  test "Can convert block into cells":
    let cells = dataSampler.getBlockCells(blk)

    check:
      cells.len == (bytesPerBlock div CellSize.int)
      cells[0] == cell0Bytes
      cells[1] == cell1Bytes
      cells[2] == cell2Bytes

  test "Can create mini tree for block cells":
    let miniTree = dataSampler.getBlockCellMiniTree(blk).tryGet()

    let
      cell0Proof = miniTree.getProof(0).tryGet()
      cell1Proof = miniTree.getProof(1).tryGet()
      cell2Proof = miniTree.getProof(2).tryGet()

    check:
      cell0Proof.verifyDataBlock(cell0Bytes, miniTree.root).tryGet()
      cell1Proof.verifyDataBlock(cell1Bytes, miniTree.root).tryGet()
      cell2Proof.verifyDataBlock(cell2Bytes, miniTree.root).tryGet()

  test "Can gather proof input":
    # This is the main function for this module, and what it's all about.
    let
      nSamples = 3
      input = (await dataSampler.getProofInput(challenge, nSamples)).tryget()

    proc equal(a: FieldElement, b: FieldElement): bool =
      a.toDecimal() == b.toDecimal()

    proc toStr(proof: MerkleProof): string =
      toHex(proof.nodesBuffer)

    let
      expectedBlockSlotProofs = getExpectedBlockSlotProofs()
      expectedCellBlockProofs = getExpectedCellBlockProofs()
      expectedCellData = getExpectedCellData()

    check:
      equal(input.datasetRoot, datasetRootHash)
      equal(input.entropy, challenge)
      input.numberOfCellsInSlot == (bytesPerBlock * numberOfSlotBlocks).uint64 div CellSize
      input.numberOfSlots == slot.request.ask.slots
      input.datasetSlotIndex == slot.slotIndex.truncate(uint64)
      equal(input.slotRoot, toF(1234)) # TODO - when slotPoseidonTree is a poseidon tree, its root should be a FieldElement.
      input.datasetToSlotProof == datasetToSlotProof

      # block-slot proofs
      input.proofSamples[0].slotBlockIndex == 2
      input.proofSamples[1].slotBlockIndex == 1
      input.proofSamples[2].slotBlockIndex == 1
      toStr(input.proofSamples[0].blockSlotProof) == expectedBlockSlotProofs[0]
      toStr(input.proofSamples[1].blockSlotProof) == expectedBlockSlotProofs[1]
      toStr(input.proofSamples[2].blockSlotProof) == expectedBlockSlotProofs[2]

      # cell-block proofs
      input.proofSamples[0].blockCellIndex == 10
      input.proofSamples[1].blockCellIndex == 9
      input.proofSamples[2].blockCellIndex == 19
      toStr(input.proofSamples[0].cellBlockProof) == expectedCellBlockProofs[0]
      toStr(input.proofSamples[1].cellBlockProof) == expectedCellBlockProofs[1]
      toStr(input.proofSamples[2].cellBlockProof) == expectedCellBlockProofs[2]

      # cell data
      toHex(input.proofSamples[0].cellData) == expectedCellData[0]
      toHex(input.proofSamples[1].cellData) == expectedCellData[1]
      toHex(input.proofSamples[2].cellData) == expectedCellData[2]

  for (input, expected) in [(10, 0), (31, 0), (32, 1), (63, 1), (64, 2)]:
    test "Can get slotBlockIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let
        slotCellIndex = input.uint64
        slotBlockIndex = dataSampler.getSlotBlockIndexForSlotCellIndex(slotCellIndex)

      check:
        slotBlockIndex == expected.uint64

  for (input, expected) in [(10, 10), (31, 31), (32, 0), (63, 31), (64, 0)]:
    test "Can get blockCellIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let
        slotCellIndex = input.uint64
        blockCellIndex = dataSampler.getBlockCellIndexForSlotCellIndex(slotCellIndex)

      check:
        blockCellIndex == expected.uint64
