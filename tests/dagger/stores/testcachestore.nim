import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable/results
import pkg/dagger/stores/cachestore
import pkg/dagger/chunker

import ../helpers

suite "Memory Store tests":
  test "putBlock":
    let
      newBlock = Block.init("New Block".toBytes()).tryGet()
      store = CacheStore.new()

    check await store.putBlock(newBlock)
    check newBlock.cid in store

  test "getBlock":
    let
      newBlock = Block.init("New Block".toBytes()).tryGet()
      store = CacheStore.new(@[newBlock])

    let blk = await store.getBlock(newBlock.cid)
    check blk.isOk
    check blk == newBlock.success

  test "fail getBlock":
    let
      newBlock = Block.init("New Block".toBytes()).tryGet()
      store = CacheStore.new(@[])

    let blk = await store.getBlock(newBlock.cid)
    check blk.isErr
    check blk.error of system.KeyError

  test "hasBlock":
    let
      newBlock = Block.init("New Block".toBytes()).tryGet()
      store = CacheStore.new(@[newBlock])

    check store.hasBlock(newBlock.cid)

  test "fail hasBlock":
    let
      newBlock = Block.init("New Block".toBytes()).tryGet()
      store = CacheStore.new(@[])

    check not store.hasBlock(newBlock.cid)

  test "delBlock":
    let
      newBlock = Block.init("New Block".toBytes()).tryGet()
      store = CacheStore.new(@[newBlock])

    check await store.delBlock(newBlock.cid)
    check newBlock.cid notin store
