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
  let
    capacity = 100
    blk = createTestBlock(10)
    emptyBlk = blk.cid.emptyBlock

  test "Should store initial blocks":
    let store = MemoryStore.new([blk], capacity)

    let receivedBlk = (await store.getBlock(blk.cid)).tryGet()

    check receivedBlk == blk

  test "getBlock should return empty block":
    let store = MemoryStore.new([], capacity)

    let received = (await store.getBlock(emptyBlk.cid)).tryGet()

    check:
      emptyBlk == received

  test "hasBlock should return true for empty block":
    let store = MemoryStore.new([], capacity)

    let hasBlock = (await store.hasBlock(emptyBlk.cid)).tryGet()

    check hasBlock

  test "getBlock should return failure when getting an unknown block":
    let
      store = MemoryStore.new([blk], capacity)
      unknownBlock = createTestBlock(11)

    let received = (await store.getBlock(unknownBlock.cid))

    check received.isErr

  test "putBlock should increase bytes used":
    let store = MemoryStore.new([], capacity)

    check:
      store.capacity == capacity
      store.bytesUsed == 0

    (await store.putBlock(blk)).tryGet()

    check:
      store.capacity == capacity
      store.bytesUsed == blk.data.len

  test "putBlock should fail when memorystore is full":
    let
      largeBlk = createTestBlock(capacity)
      store = MemoryStore.new([largeBlk], capacity)

    check:
      store.capacity == capacity
      store.bytesUsed == capacity

    let response  = await store.putBlock(blk)

    check response.isErr

  test "putBlock should ignore empty blocks":
    let store = MemoryStore.new([], capacity)

    (await store.putBlock(emptyBlk)).tryGet()
    (await store.putBlock(emptyBlk)).tryGet()
    (await store.putBlock(emptyBlk)).tryGet()

    check:
      store.capacity == capacity
      store.bytesUsed == 0

  test "delBlock should ignore empty blocks":
    let store = MemoryStore.new([], capacity)

    (await store.delBlock(emptyBlk.cid)).tryGet()
    (await store.delBlock(emptyBlk.cid)).tryGet()
    (await store.delBlock(emptyBlk.cid)).tryGet()

    check:
      store.capacity == capacity
      store.bytesUsed == 0

commonBlockStoreTests(
  "MemoryStore", proc: BlockStore =
    BlockStore(MemoryStore.new([]))
)
