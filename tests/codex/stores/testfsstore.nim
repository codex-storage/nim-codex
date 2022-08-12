import std/os
import std/options

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

proc runSuite(cache: bool) =
  suite "FS Store " & (if cache: "(cache enabled)" else: "(cache disabled)"):
    var
      store: FSStore
      repoDir: string
      newBlock = bt.Block.new("New Block".toBytes()).tryGet()

    setup:
      repoDir = getAppDir() / "repo"
      createDir(repoDir)

      if cache:
        store = FSStore.new(repoDir)
      else:
        store = FSStore.new(repoDir, postfixLen = 2, cache = nil)

    teardown:
      removeDir(repoDir)

    test "putBlock":
      (await store.putBlock(newBlock)).tryGet()
      check:
        fileExists(store.blockPath(newBlock.cid))
        (await store.hasBlock(newBlock.cid)).tryGet()
        await newBlock.cid in store

    test "getBlock":
      createDir(store.blockPath(newBlock.cid).parentDir)
      writeFile(store.blockPath(newBlock.cid), newBlock.data)
      let blk = await store.getBlock(newBlock.cid)
      check blk.tryGet() == newBlock

    test "fail getBlock":
      let blk = await store.getBlock(newBlock.cid)
      check:
        blk.isErr
        blk.error.kind == BlockNotFoundErr

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

runSuite(cache = true)
runSuite(cache = false)
