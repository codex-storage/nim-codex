import std/oids
import std/options
import std/os
import std/random
import std/sequtils
import std/sets

import pkg/asynctest
import pkg/chronos
import pkg/stew/byteutils

import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/stores

import ../helpers

proc runSuite(cache: bool) =
  suite "SQLite Store " & (if cache: "(cache enabled)" else: "(cache disabled)"):
    randomize()

    var
      store: SQLiteStore

    let
      repoDir = getAppDir() / "repo"

    proc randomBlock(): bt.Block =
      let
        blockRes = bt.Block.new(($genOid()).toBytes)

      require(blockRes.isOk)
      blockRes.get

    var
      newBlock: bt.Block

    setup:
      removeDir(repoDir)
      require(not dirExists(repoDir))
      createDir(repoDir)

      if cache:
        store = SQLiteStore.new(repoDir)
      else:
        store = SQLiteStore.new(repoDir, cache = nil)

      newBlock = randomBlock()

    teardown:
      if not store.isNil: await store.close
      store = nil
      removeDir(repoDir)
      require(not dirExists(repoDir))

    test "putBlock":
      let
        blkKeyRes = blockKey(newBlock.cid)

      assert blkKeyRes.isOk

      let
        blkKey = blkKeyRes.get

      var
        # bypass enabled cache
        containsRes = await store.datastore.contains(blkKey)

      assert containsRes.isOk
      assert not containsRes.get

      let
        putRes = await store.putBlock(newBlock)

      check: putRes.isOk

      # bypass enabled cache
      containsRes = await store.datastore.contains(blkKey)

      assert containsRes.isOk

      check: containsRes.get

    test "getBlock":
      var
        r = rand(100)

      # put `r` number of random blocks before putting newBlock
      if r > 0:
        for _ in 0..r:
          let
            b = randomBlock()
            kRes = blockKey(b.cid)

          assert kRes.isOk

          let
            # bypass enabled cache
            pRes = await store.datastore.put(kRes.get, b.data)

          assert pRes.isOk

      let
        blkKeyRes = blockKey(newBlock.cid)

      assert blkKeyRes.isOk

      var
        # bypass enabled cache
        putRes = await store.datastore.put(blkKeyRes.get, newBlock.data)

      assert putRes.isOk

      r = rand(100)

      # put `r` number of random blocks after putting newBlock
      if r > 0:
        for _ in 0..r:
          let
            b = randomBlock()
            kRes = blockKey(b.cid)

          assert kRes.isOk

          let
            # bypass enabled cache
            pRes = await store.datastore.put(kRes.get, b.data)

          assert pRes.isOk

      var
        # get from database
        getRes = await store.getBlock(newBlock.cid)

      check:
        getRes.isOk
        getRes.get == newBlock

      # get from enabled cache
      getRes = await store.getBlock(newBlock.cid)

      check:
        getRes.isOk
        getRes.get == newBlock

    test "fail getBlock":
      let
        getRes = await store.getBlock(newBlock.cid)

      check: getRes.isErr

      # PASS!
      when getRes.error is (ref CatchableError):
        check: true
        echo "PASS: when getRes.error is (ref CatchableError)"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"
      else:
        check: false

      # sanity check
      when getRes.error is CatchableError:
        check: true
      else:
        check: false
        echo "FAIL: when getRes.error is CatchableError"
        echo "NOTE: sanity check for ref vs. non-ref; msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"

      # `when..is` does not work for error types that inherit from
      # CatchableError, need to use a runtime check not a compile-time check

      # FAIL!
      when getRes.error is (ref CodexError):
        check: true
      else:
        check: false
        echo "FAIL: when getRes.error is (ref CodexError)"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"

      # FAIL!
      when getRes.error is (ref BlockNotFoundError):
        check: true
      else:
        check: false
        echo "FAIL: when getRes.error is (ref BlockNotFoundError)"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"

      # PASS!
      if getRes.error is (ref CatchableError):
        check: true
        echo "PASS: if getRes.error is (ref CatchableError)"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"
      else:
        check: false

      # sanity check
      if getRes.error is CatchableError:
        check: true
      else:
        check: false
        echo "FAIL: if getRes.error is CatchableError"
        echo "NOTE: sanity check for ref vs. non-ref; msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"

      # `if..is` does not work either

      # FAIL!
      if getRes.error is (ref CodexError):
        check: true
      else:
        check: false
        echo "FAIL: if getRes.error is (ref CodexError)"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"

      if getRes.error is (ref BlockNotFoundError):
        check: true
      else:
        check: false
        echo "FAIL: if getRes.error is (ref BlockNotFoundError)"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"

      # `case..of` does not compile with `of [type]` or `of (ref [type])`
      # but `if..of` does work!

      # PASS!
      if getRes.error of (ref CatchableError):
        check: true
        echo "PASS: if getRes.error of (ref CatchableError)"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"
      else:
        check: false

      # PASS!
      if getRes.error of CatchableError:
        check: true
        echo "PASS: if getRes.error of CatchableError"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"
      else:
        check: false

      # PASS!
      if getRes.error of (ref CodexError):
        check: true
        echo "PASS: if getRes.error of (ref CodexError)"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"
      else:
        check: false

        # PASS!
      if getRes.error of CodexError:
        check: true
        echo "PASS: if getRes.error of CodexError"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"
      else:
        check: false

      # PASS!
      if getRes.error of (ref BlockNotFoundError):
        check: true
        echo "PASS: if getRes.error of (ref BlockNotFoundError)"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"
      else:
        check: false

      # PASS!
      if getRes.error of BlockNotFoundError:
        check: true
        echo "PASS: if getRes.error of BlockNotFoundError"
        echo "NOTE: msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"
      else:
        check: false

      # sanity check
      if getRes.error of (ref ValueError):
        check: true
      else:
        check: false
        echo "FAIL: if getRes.error of (ref ValueError)"
        echo "NOTE: sanity check for error type not in inheritance chain; msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"

      # sanity check
      if getRes.error of ValueError:
        check: true
      else:
        check: false
        echo "FAIL: if getRes.error of ValueError"
        echo "NOTE: sanity check for error type not in inheritance chain; msg string is what we expect: " & getRes.error.msg
        check: getRes.error.msg == "Block not in database"

    test "hasBlock":
      let
        putRes = await store.putBlock(newBlock)

      assert putRes.isOk

      let
        hasRes = await store.hasBlock(newBlock.cid)

      check:
        hasRes.isOk
        hasRes.get
        await newBlock.cid in store

    test "fail hasBlock":
      let
        hasRes = await store.hasBlock(newBlock.cid)

      check:
        hasRes.isOk
        not hasRes.get
        not (await newBlock.cid in store)

    test "listBlocks":
      var
        newBlocks: seq[bt.Block]

      for _ in 0..99:
        let
          b = randomBlock()
          pRes = await store.putBlock(b)

        assert pRes.isOk

        newBlocks.add(b)

      var
        called = 0
        cids = toHashSet(newBlocks.mapIt(it.cid))

      let
        onBlock = proc(cid: Cid) {.async, gcsafe.} =
          check: cid in cids
          if cid in cids:
            inc called
            cids.excl(cid)

        listRes = await store.listBlocks(onBlock)

      check:
        listRes.isOk
        called == newBlocks.len

    test "delBlock":
      let
        putRes = await store.putBlock(newBlock)

      assert putRes.isOk
      assert (await newBlock.cid in store)

      let
        delRes = await store.delBlock(newBlock.cid)

      check:
        delRes.isOk
        not (await newBlock.cid in store)

# runSuite(cache = true)
runSuite(cache = false)
