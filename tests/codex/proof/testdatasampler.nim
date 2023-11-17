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

import ../helpers
import ../examples

let
  bytesPerBlock = 64 * 1024
  numberOfSlotBlocks = 10

asyncchecksuite "Test proof datasampler":
  let chunker = RandomChunker.new(Rng.instance(),
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

  test "Should pass":
    check true
