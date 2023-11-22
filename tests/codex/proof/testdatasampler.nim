import std/os
import std/strutils
import std/sequtils
import std/sugar
import std/random

import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/poseidon2/types
import pkg/poseidon2
import pkg/chronos
import pkg/asynctest
import pkg/stew/byteutils
import pkg/stew/endians2
import pkg/datastore
import pkg/codex/rng
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/clock
import pkg/codex/utils/asynciter
import pkg/codex/contracts/requests
import pkg/codex/contracts

import pkg/codex/proof/datasampler
import pkg/codex/proof/misc

import ../helpers
import ../examples

let
  bytesPerBlock = 64 * 1024
  numberOfSlotBlocks = 16
  challenge: DSFieldElement = toF(12345)
  slotRootHash: DSFieldElement = toF(6789)
  slot = Slot(
    request: StorageRequest(
      client: Address.example,
      ask: StorageAsk(
        slots: 10,
        slotSize: u256(bytesPerBlock * numberOfSlotBlocks),
        duration: UInt256.example,
        proofProbability: UInt256.example,
        reward: UInt256.example,
        collateral: UInt256.example,
        maxSlotLoss: 123.uint64
      ),
      content: StorageContent(
        cid: "cidstringtodo",
        erasure: StorageErasure(),
        por: StoragePoR()
      ),
      expiry: UInt256.example,
      nonce: Nonce.example
    ),
    slotIndex: u256(3)
  )

asyncchecksuite "Test proof datasampler":
  let chunker = RandomChunker.new(rng.Rng.instance(),
    size = bytesPerBlock * numberOfSlotBlocks,
    chunkSize = bytesPerBlock)

  var slotBlocks: seq[bt.Block]

  proc createSlotBlocks(): Future[void] {.async.} =
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break
      slotBlocks.add(bt.Block.new(chunk).tryGet())

  setup:
    await createSlotBlocks()

  test "Number of cells is a power of two":
    # This is to check that the data used for testing is sane.
    proc isPow2(value: int): bool =
      let log2 = ceilingLog2(value)
      return (1 shl log2) == value

    let numberOfCells = getNumberOfCellsInSlot(slot).int

    check:
      isPow2(numberOfCells)

  test "Extract low bits":
    proc extract(value: int, nBits: int): uint64 =
      let big = toF(value).toBig()
      return extractLowBits(big, nBits)

    check:
      extract(0x88, 4) == 0x8.uint64
      extract(0x88, 7) == 0x8.uint64
      extract(0x9A, 5) == 0x1A.uint64
      extract(0x9A, 7) == 0x1A.uint64
      extract(0x1248, 10) == 0x248.uint64
      extract(0x1248, 12) == 0x248.uint64
      # extract(0x1248306A560C9AC0, 10) == 0x2C0.uint64
      # extract(0x1248306A560C9AC0, 12) == 0xAC0.uint64
      # extract(0x1248306A560C9AC0, 50) == 0x306A560C9AC0.uint64
      # extract(0x1248306A560C9AC0, 52) == 0x8306A560C9AC0.uint64

  test "Should calculate total number of cells in Slot":
    let
      slotSizeInBytes = (slot.request.ask.slotSize).truncate(uint64)
      expectedNumberOfCells = slotSizeInBytes div CellSize

    check:
      expectedNumberOfCells == 512
      expectedNumberOfCells == getNumberOfCellsInSlot(slot)

  let knownIndices = @[178.uint64, 277.uint64, 366.uint64]

  test "Can find single cell index":
    let numberOfCells = getNumberOfCellsInSlot(slot)

    proc cellIndex(i: int): DSCellIndex =
      let counter: DSFieldElement = toF(i)
      return findCellIndex(slotRootHash, challenge, counter, numberOfCells)

    proc getExpectedIndex(i: int): DSCellIndex =
      let hash = Sponge.digest(@[slotRootHash, challenge, toF(i)], rate = 2)
      return extractLowBits(hash.toBig(), ceilingLog2(numberOfCells.int))

    check:
      cellIndex(1) == getExpectedIndex(1)
      cellIndex(1) == knownIndices[0]
      cellIndex(2) == getExpectedIndex(2)
      cellIndex(2) == knownIndices[1]
      cellIndex(3) == getExpectedIndex(3)
      cellIndex(3) == knownIndices[2]

  test "Can find sequence of cell indices":
    proc cellIndices(n: int): seq[DSCellIndex]  =
      findCellIndices(slot, slotRootHash, challenge, n)

    let numberOfCells = getNumberOfCellsInSlot(slot)
    proc getExpectedIndices(n: int): seq[DSCellIndex]  =
      return collect(newSeq, (for i in 1..n: findCellIndex(slotRootHash, challenge, toF(i), numberOfCells)))

    check:
      cellIndices(3) == getExpectedIndices(3)
      cellIndices(3) == knownIndices

  for (input, expected) in [(10, 0), (31, 0), (32, 1), (63, 1), (64, 2)]:
    test "Can get slotBlockIndex from cell index (" & $input & " -> " & $expected & ")":
      let
        cellIndex = input.uint64
        blockSize = (64 * 1024).uint64

        slotBlockIndex = getSlotBlockIndex(cellIndex, blockSize)

      check:
        slotBlockIndex == expected.uint64

  for (input, expected) in [(10, 10), (31, 31), (32, 0), (63, 31), (64, 0)]:
    test "Can get cellIndexInBlock from cell index (" & $input & " -> " & $expected & ")":
      let
        cellIndex = input.uint64
        blockSize = (64 * 1024).uint64

        cellIndexInBlock = getCellIndexInBlock(cellIndex, blockSize)

      check:
        cellIndexInBlock == expected.uint64

  test "Can get sample from block":
    let
      blockSize = CellSize * 2
      bytes = newSeqWith(blockSize.int, rand(uint8))
      blk = bt.Block.new(bytes).tryGet()

      sample0 = getSampleFromBlock(blk, 0, blockSize.uint64)
      sample1 = getSampleFromBlock(blk, 1, blockSize.uint64)

    check:
      sample0 == bytes[0..<CellSize]
      sample1 == bytes[CellSize..^1]

    # proc getSampleFromBlock(blk: bt.Block, cellIndex: DSCellIndex, blockSize: uint64): DSSample


    # let length = rand(4096)
  # let bytes = newSeqWith(length, rand(uint8))
  # bt.Block.new(bytes).tryGet()
