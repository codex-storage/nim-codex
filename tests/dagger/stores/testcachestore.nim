import std/strutils

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable/results
import pkg/dagger/stores/cachestore
import pkg/dagger/chunker

import ../helpers

suite "Cache Store tests":
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

    check:
      await store.putBlock(newBlock1)
      newBlock1.cid in store

    # block size bigger than entire cache
    store = CacheStore.new(cacheSize = 99, chunkSize = 98)
    check not await store.putBlock(newBlock1)

    # block being added causes removal of LRU block
    store = CacheStore.new(
              @[newBlock1, newBlock2, newBlock3],
              cacheSize = 200,
              chunkSize = 1)
    check:
      not store.hasBlock(newBlock1.cid)
      store.hasBlock(newBlock2.cid)
      store.hasBlock(newBlock3.cid)
      store.currentSize == newBlock2.data.len + newBlock3.data.len # 200

  test "getBlock":
    store = CacheStore.new(@[newBlock])

    let blk = await store.getBlock(newBlock.cid)

    check:
      blk.isOk
      blk.get == newBlock

  test "fail getBlock":
    let blk = await store.getBlock(newBlock.cid)

    check:
      blk.isErr
      blk.error of system.KeyError

  test "hasBlock":
    let store = CacheStore.new(@[newBlock])

    check store.hasBlock(newBlock.cid)

  test "fail hasBlock":
    check not store.hasBlock(newBlock.cid)

  test "delBlock":
    # empty cache
    check not await store.delBlock(newBlock1.cid)

    # successfully deleted
    discard await store.putBlock(newBlock1)
    check await store.delBlock(newBlock1.cid)

    # deletes item should decrement size
    store = CacheStore.new(@[newBlock1, newBlock2, newBlock3])
    check:
      store.currentSize == 300
      await store.delBlock(newBlock2.cid)
      store.currentSize == 200
      newBlock2.cid notin store

  test "listBlocks":
    discard await store.putBlock(newBlock1)

    var listed = false
    await store.listBlocks(
      proc(blk: Block) {.gcsafe, async.} =
        check blk.cid in store
        listed = true
    )

    check listed
