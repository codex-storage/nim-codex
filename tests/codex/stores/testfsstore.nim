import std/os

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils

import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt

import ../helpers

suite "FS Store":
  let
    (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name

  var
    store: FSStore
    repoDir: string
    newBlock = bt.Block.new("New Block".toBytes()).tryGet()

  setup:
    repoDir = path.parentDir / "repo"
    createDir(repoDir)
    store = FSStore.new(repoDir)

  teardown:
    removeDir(repoDir)

  test "putBlock":
    check:
      await store.putBlock(newBlock)
      fileExists(store.blockPath(newBlock.cid))
      (await store.hasBlock(newBlock.cid)).tryGet()
      await newBlock.cid in store

  test "getBlock":
    createDir(store.blockPath(newBlock.cid).parentDir)
    writeFile(store.blockPath(newBlock.cid), newBlock.data)
    let blk = await store.getBlock(newBlock.cid)
    check blk.option == newBlock.some

  test "fail getBlock":
    let blk = await store.getBlock(newBlock.cid)
    check blk.isErr

  test "hasBlock":
    createDir(store.blockPath(newBlock.cid).parentDir)
    writeFile(store.blockPath(newBlock.cid), newBlock.data)

    check:
      (await store.hasBlock(newBlock.cid)).tryGet()
      await newBlock.cid in store

  test "fail hasBlock":
    check:
      not (await store.hasBlock(newBlock.cid)).tryGet()
      not (await newBlock.cid in store)

  test "listBlocks":
    createDir(store.blockPath(newBlock.cid).parentDir)
    writeFile(store.blockPath(newBlock.cid), newBlock.data)

    (await store.listBlocks(
      proc(cid: Cid) {.gcsafe, async.} =
        check cid == newBlock.cid
    )).tryGet()

  test "delBlock":
    createDir(store.blockPath(newBlock.cid).parentDir)
    writeFile(store.blockPath(newBlock.cid), newBlock.data)

    (await store.delBlock(newBlock.cid)).tryGet()
    check not fileExists(store.blockPath(newBlock.cid))
