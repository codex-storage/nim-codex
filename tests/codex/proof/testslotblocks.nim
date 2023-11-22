import std/os
import std/strutils
import std/sequtils
import std/sugar

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

import pkg/codex/proof/slotblocks

import ../helpers
import ../examples

let
  bytesPerBlock = 64 * 1024
  numberOfSlotBlocks = 16
  slotIndex = 3


asyncchecksuite "Test slotblocks":
  let
    localStore = CacheStore.new()
    manifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 100.MiBs)
    manifestBlock = bt.Block.new(manifest.encode().tryGet(), codec = DagPBCodec).tryGet()
    slot = Slot(
      request: StorageRequest(
        ask: StorageAsk(
          slotSize: u256(bytesPerBlock * numberOfSlotBlocks)
        ),
        content: StorageContent(
          cid: $manifestBlock.cid
        ),
      ),
      slotIndex: u256(slotIndex)
    )

  # let chunker = RandomChunker.new(rng.Rng.instance(),
  #   size = bytesPerBlock * numberOfSlotBlocks,
  #   chunkSize = bytesPerBlock)

  # var slotBlocks: seq[bt.Block]

  # proc createSlotBlocks(): Future[void] {.async.} =
  #   while true:
  #     let chunk = await chunker.getBytes()
  #     if chunk.len <= 0:
  #       break
  #     slotBlocks.add(bt.Block.new(chunk).tryGet())

  # setup:
  #   await createSlotBlocks()

  test "Can get tree root for slot":
    let cid = (await getTreeCidForSlot(slot, localStore)).tryGet()

    check:
      cid == manifest.treeCid
