import std/os
import std/strutils
import std/sequtils

import pkg/questionable
import pkg/questionable/results

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

import ../helpers
import ../examples

let
  bytesPerBlock = 64 * 1024
  numberOfSlotBlocks = 10
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

  test "Should calculate total number of cells in Slot":
    let
      slotSizeInBytes = slot.request.ask.slotSize
      expectedNumberOfCells = slotSizeInBytes div CellSize

    check:
      expectedNumberOfCells == 320
      expectedNumberOfCells == getNumberOfCellsInSlot(slot)


