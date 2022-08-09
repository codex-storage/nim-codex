import std/strutils
import std/options

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable/results
import pkg/codex/stores/cachestore
import pkg/codex/chunker

import ../helpers

suite "Cache Store":
  var
    newBlock, newBlock1, newBlock2, newBlock3: Block
    store: CacheStore

  setup:
    newBlock = Block.new("New Kids on the Block".toBytes()).tryGet()
    newBlock1 = Block.new("1".repeat(100).toBytes()).tryGet()
    newBlock2 = Block.new("2".repeat(100).toBytes()).tryGet()
    newBlock3 = Block.new("3".repeat(100).toBytes()).tryGet()
    store = CacheStore.new()

  test "constructor":
    # cache size cannot be smaller than chunk size
    expect ValueError:
      discard CacheStore.new(cacheSize = 1, chunkSize = 2)

    store = CacheStore.new(cacheSize = 100, chunkSize = 1)
    check store.currentSize == 0
    store = CacheStore.new(@[newBlock1, newBlock2, newBlock3])
    check store.currentSize == 300

    # initial cache blocks total more than cache size, currentSize should
    # never exceed max cache size
    store = CacheStore.new(
              blocks = @[newBlock1, newBlock2, newBlock3],
              cacheSize = 200,
              chunkSize = 1)
    check store.currentSize == 200

    # cache size cannot be less than chunks size
    expect ValueError:
      discard CacheStore.new(
                cacheSize = 99,
                chunkSize = 100)

  test "putBlock":

    (await store.putBlock(newBlock1)).tryGet()
    check (await store.hasBlock(newBlock1.cid)).tryGet()

    # block size bigger than entire cache
    store = CacheStore.new(cacheSize = 99, chunkSize = 98)
    (await store.putBlock(newBlock1)).tryGet()
    check not (await store.hasBlock(newBlock1.cid)).tryGet()

    # block being added causes removal of LRU block
    store = CacheStore.new(
              @[newBlock1, newBlock2, newBlock3],
              cacheSize = 200,
              chunkSize = 1)
    check:
      not (await store.hasBlock(newBlock1.cid)).tryGet()
      (await store.hasBlock(newBlock2.cid)).tryGet()
      (await store.hasBlock(newBlock2.cid)).tryGet()
      store.currentSize == newBlock2.data.len + newBlock3.data.len # 200

  test "getBlock":
    store = CacheStore.new(@[newBlock])

    let blk = await store.getBlock(newBlock.cid)
    check blk.tryGet() == newBlock

  test "fail getBlock":
    let blk = await store.getBlock(newBlock.cid)
    check blk.isErr

  test "hasBlock":
    let store = CacheStore.new(@[newBlock])
    check:
      (await store.hasBlock(newBlock.cid)).tryGet()
      await newBlock.cid in store

  test "fail hasBlock":
    check:
      not (await store.hasBlock(newBlock.cid)).tryGet()
      not (await newBlock.cid in store)

  test "delBlock":
    # empty cache
    (await store.delBlock(newBlock1.cid)).tryGet()
    check not (await store.hasBlock(newBlock1.cid)).tryGet()

    (await store.putBlock(newBlock1)).tryGet()
    check (await store.hasBlock(newBlock1.cid)).tryGet()

    # successfully deleted
    (await store.delBlock(newBlock1.cid)).tryGet()
    check not (await store.hasBlock(newBlock1.cid)).tryGet()

    # deletes item should decrement size
    store = CacheStore.new(@[newBlock1, newBlock2, newBlock3])
    check:
      store.currentSize == 300

    (await store.delBlock(newBlock2.cid)).tryGet()

    check:
      store.currentSize == 200
      not (await store.hasBlock(newBlock2.cid)).tryGet()

  test "listBlocks":
    (await store.putBlock(newBlock1)).tryGet()

    var listed = false
    (await store.listBlocks(
      proc(cid: Cid) {.gcsafe, async.} =
        check (await store.hasBlock(cid)).tryGet()
        listed = true
    )).tryGet()

    check listed
