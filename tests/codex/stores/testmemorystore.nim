import pkg/questionable/results

import pkg/chronos
import pkg/asynctest
import pkg/libp2p

import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt

import ../helpers
import ./commonstoretests

suite "MemoryStore":
  test "Should store initial blocks":
    let
      capacity = 100
      blk = createTestBlock(10)

    let store = MemoryStore.new([blk], capacity)

    let receivedBlk = await store.getBlock(blk.cid)

    check receivedBlk.tryGet() == blk

commonBlockStoreTests(
  "MemoryStore", proc: BlockStore =
    BlockStore(MemoryStore.new([]))
)
