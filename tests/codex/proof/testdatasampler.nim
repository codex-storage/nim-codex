import std/os
import std/strutils
import std/sequtils

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

  test "number of cells is a power of two":
    proc isPow2(value: int): bool =
      let log2 = ceilingLog2(value)
      return (1 shl log2) == value

    let numberOfCells = getNumberOfCellsInSlot(slot)

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

  test "Should calculate total number of cells in Slot":
    let
      slotSizeInBytes = slot.request.ask.slotSize
      expectedNumberOfCells = (slotSizeInBytes div CellSize).truncate(int)

    check:
      expectedNumberOfCells == 512
      expectedNumberOfCells == getNumberOfCellsInSlot(slot)

  test "Can find single cell index":
    let
      counter: DSFieldElement = toF(1)
      numberOfCells = getNumberOfCellsInSlot(slot)
      cellIndex = findCellIndex(slotRootHash, challenge, counter, numberOfCells)

    check:
      cellIndex == 2
