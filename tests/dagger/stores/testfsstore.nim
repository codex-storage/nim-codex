import std/os

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils

import pkg/dagger/stores/memorystore
import pkg/dagger/chunker
import pkg/dagger/stores

import ../helpers

suite "FS Store":
  let
    (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name

  var
    store: FSStore
    repoDir: string
    newBlock = Block.init("New Block".toBytes()).get()

  setup:
    repoDir = path.parentDir / "repo"
    createDir(repoDir)
    store = FSStore.new(repoDir)

  teardown:
    removeDir(repoDir)

  test "putBlock":
    check await store.putBlock(newBlock)
    check fileExists(store.blockPath(newBlock.cid))
    check newBlock.cid in store

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

    check store.hasBlock(newBlock.cid)

  test "fail hasBlock":
    check not store.hasBlock(newBlock.cid)

  test "delBlock":
    createDir(store.blockPath(newBlock.cid).parentDir)
    writeFile(store.blockPath(newBlock.cid), newBlock.data)

    check await store.delBlock(newBlock.cid)
    check not fileExists(store.blockPath(newBlock.cid))
