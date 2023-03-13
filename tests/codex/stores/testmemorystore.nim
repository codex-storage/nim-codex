import std/os
import std/strutils
import std/sequtils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils
import pkg/stew/endians2
import pkg/datastore

import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/clock

import ../helpers
import ../helpers/mockclock
import ./commonstoretests

suite "MemoryStore":
  test "Should store initial blocks":
    let
      capacity = 100
      chunkSize = 10
      blk = createTestBlock(10)

    let store = MemoryStore.new([blk], capacity, chunkSize)

    let receivedBlk = await store.getBlock(blk.cid)

    check receivedBlk.tryGet() == blk

commonBlockStoreTests(
  "MemoryStore", proc: BlockStore =
    BlockStore(MemoryStore.new([]))
)
