import std/os

import pkg/asynctest
import pkg/chronos
import pkg/dagger/stores
import pkg/questionable
import pkg/questionable/results
# import pkg/libp2p
# import pkg/stew/byteutils

# import pkg/dagger/chunker

import ./blockstoremock
import ../examples

suite "BlockStore manager":

  var
    blockStore1: BlockStoreMock
    blockStore2: BlockStoreMock
    mgr: BlockStoreManager

  setup:
    blockStore1 = BlockStoreMock.new()
    blockStore2 = BlockStoreMock.new()
    mgr = BlockStoreManager.new(
      @[BlockStore(blockStore1), BlockStore(blockStore2)])

  teardown:
    discard

  test "getBlock, should get from second block store":
    let blk = Block.example

    blockStore1.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        check cid == blk.cid
        return failure("block not found")

    blockStore2.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        return success blk

    let blkResult = await mgr.getBlock(blk.cid)
    check:
      blkResult.isOk
      !blkResult == blk

  test "getBlock, should get from first block store":
    let blk = Block.example

    blockStore1.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        check cid == blk.cid
        return success blk

    blockStore2.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        fail()
        return failure("shouldn't get here")

    let blkResult = await mgr.getBlock(blk.cid)
    check:
      blkResult.isOk
      !blkResult == blk

  test "getBlock, no block found":
    let blk = Block.example

    blockStore1.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        check cid == blk.cid
        return failure("couldn't find block")

    blockStore2.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        check cid == blk.cid
        return failure("couldn't find block")

    let blkResult = await mgr.getBlock(blk.cid)
    check:
      blkResult.isErr
      blkResult.error.msg == "Couldn't find block in any stores"

  test "getBlocks, no blocks found":
    let
      blk1 = Block.example
      blk2 = Block.example

    blockStore1.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        return failure("couldn't find block")

    blockStore2.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        return failure("couldn't find block")

    let blks = await mgr.getBlocks(@[blk1.cid, blk2.cid])
    check:
      blks.len == 0

  test "getBlocks, some blocks found":
    let
      blk1 = Block.example
      blk2 = Block.example

    blockStore1.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        return failure("couldn't find block")

    blockStore2.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        return success blk2

    let blks = await mgr.getBlocks(@[blk1.cid, blk2.cid])
    check:
      blks[0] == blk2

  test "getBlocks, all blocks found":
    let
      blk1 = Block.example
      blk2 = Block.example

    blockStore1.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        if cid == blk2.cid:
          return failure("block not found")
        else: return success blk1

    blockStore2.getBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.async.} =
        if cid == blk1.cid:
          return failure("block not found")
        else: return success blk2

    let blks = await mgr.getBlocks(@[blk1.cid, blk2.cid])
    check:
      blks == @[blk1, blk2]

  test "putBlock, all stores should successfully put block":
    let blk = Block.example

    blockStore1.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return true

    blockStore2.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return true

    let blkResult = await mgr.putBlock(blk)
    check:
      blkResult

  test "putBlock, one store should fail, result is failure":
    let blk = Block.example

    blockStore1.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return true

    blockStore2.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return false

    let blkResult = await mgr.putBlock(blk)
    check:
      not blkResult

  test "putBlock, one store should fail, result is failure, callback called":
    let
      blk = Block.example
      fut = newFuture[bool]("putBlock test")

    blockStore1.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return true

    blockStore2.onPutFail = proc(self: BlockStore, b: Block): Future[void] {.async.} =
      fut.complete(true)

    blockStore2.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return false

    let
      blkWasPut = await mgr.putBlock(blk)
      putFailCalled = await fut.wait(5.seconds)

    check:
      not blkWasPut
      putFailCalled

  test "putBlock, one store should fail, result is success, callback called":
    let
      blk = Block.example
      fut = newFuture[bool]("putBlock test")

    blockStore1.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return true

    blockStore2.canFail = true

    blockStore2.onPutFail = proc(self: BlockStore, b: Block): Future[void] {.async.} =
      fut.complete(true)

    blockStore2.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return false

    let
      blkWasPut = await mgr.putBlock(blk)
      putFailCalled = await fut.wait(5.seconds)

    check:
      blkWasPut
      putFailCalled

  test "putBlock, all stores fail, result should be false":
    let blk = Block.example

    blockStore1.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return false

    blockStore2.putBlock =
      proc(self: BlockStoreMock, b: Block): Future[bool] {.async.} =
        check b == blk
        return false

    let blkWasPut = await mgr.putBlock(blk)
    check:
      not blkWasPut

  test "putBlocks, no blocks stored":
    let
      blk1 = Block.example
      blk2 = Block.example

    blockStore1.putBlock =
      proc(self: BlockStoreMock, blk: Block): Future[bool] {.async.} =
        return false

    blockStore2.putBlock =
      proc(self: BlockStoreMock, blk: Block): Future[bool] {.async.} =
        return false

    let blksWerePut = await mgr.putBlocks(@[blk1, blk2])
    check:
      not blksWerePut

  test "putBlocks, some puts failed, overall result is failure":
    let
      blk1 = Block.example
      blk2 = Block.example

    blockStore1.putBlock =
      proc(self: BlockStoreMock, blk: Block): Future[bool] {.async.} =
        return false

    blockStore2.putBlock =
      proc(self: BlockStoreMock, blk: Block): Future[bool] {.async.} =
        return true

    let blksWerePut = await mgr.putBlocks(@[blk1, blk2])
    check:
      not blksWerePut

  test "putBlocks, some puts failed, overall result is success":
    let
      blk1 = Block.example
      blk2 = Block.example

    blockStore1.canFail = true
    blockStore1.putBlock =
      proc(self: BlockStoreMock, blk: Block): Future[bool] {.async.} =
        return false

    blockStore2.putBlock =
      proc(self: BlockStoreMock, blk: Block): Future[bool] {.async.} =
        return true

    let blksWerePut = await mgr.putBlocks(@[blk1, blk2])
    check:
      blksWerePut

  test "putBlocks, all blocks stored":
    let
      blk1 = Block.example
      blk2 = Block.example

    blockStore1.putBlock =
      proc(self: BlockStoreMock, blk: Block): Future[bool] {.async.} =
        return true

    blockStore2.putBlock =
      proc(self: BlockStoreMock, blk: Block): Future[bool] {.async.} =
        return true

    let blksWerePut = await mgr.putBlocks(@[blk1, blk2])
    check:
      blksWerePut

  test "delBlock, all stores should successfully put block":
    let blk = Block.example

    blockStore1.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return true

    blockStore2.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return true

    let blkWasDeleted = await mgr.delBlock(blk.cid)
    check:
      blkWasDeleted

  test "delBlock, one store should fail, result is failure":
    let blk = Block.example

    blockStore1.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return true

    blockStore2.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return false

    let blkWasDeleted = await mgr.delBlock(blk.cid)
    check:
      not blkWasDeleted

  test "delBlock, one store should fail, result is failure, callback called":
    let
      blk = Block.example
      fut = newFuture[bool]("delBlock test")

    blockStore1.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return true

    blockStore2.onDelFail = proc(self: BlockStore, cid: Cid): Future[void] {.async.} =
      fut.complete(true)

    blockStore2.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return false

    let
      blkWasDeleted = await mgr.delBlock(blk.cid)
      delFailCalled = await fut.wait(5.seconds)

    check:
      not blkWasDeleted
      delFailCalled

  test "delBlock, one store should fail, result is success, callback called":
    let
      blk = Block.example
      fut = newFuture[bool]("delBlock test")

    blockStore1.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return true

    blockStore2.canFail = true

    blockStore2.onDelFail = proc(self: BlockStore, cid: Cid): Future[void] {.async.} =
      fut.complete(true)

    blockStore2.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return false

    let
      blkWasDeleted = await mgr.delBlock(blk.cid)
      delFailCalled = await fut.wait(5.seconds)

    check:
      blkWasDeleted
      delFailCalled

  test "delBlock, all stores fail, result should be false":
    let blk = Block.example

    blockStore1.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return false

    blockStore2.delBlock =
      proc(self: BlockStoreMock, cid: Cid): Future[bool] {.async.} =
        check cid == blk.cid
        return false

    let blkWasDeleted = await mgr.delBlock(blk.cid)
    check:
      not blkWasDeleted

  test "hasBlock, should have block in second block store":
    let blk = Block.example

    blockStore1.hasBlock =
      proc(self: BlockStoreMock, cid: Cid): bool
          {.raises: [Defect, AssertionError].} =
        return false

    blockStore2.hasBlock =
      proc(self: BlockStoreMock, cid: Cid): bool
          {.raises: [Defect, AssertionError].} =
        return true

    check:
      mgr.hasBlock(blk.cid)
      mgr.contains(blk.cid) # alias to hasBlock

  test "hasBlock, should have block in first block store":
    let blk = Block.example
    var wasChecked = false

    blockStore1.hasBlock =
      proc(self: BlockStoreMock, cid: Cid): bool
          {.raises: [Defect, AssertionError].} =
        return true

    blockStore2.hasBlock =
      proc(self: BlockStoreMock, cid: Cid): bool
          {.raises: [Defect, AssertionError].} =
        wasChecked = true
        return false

    check:
      mgr.hasBlock(blk.cid)
      not wasChecked

  test "hasBlock, no block found":
    let blk = Block.example

    blockStore1.hasBlock =
      proc(self: BlockStoreMock, cid: Cid): bool
          {.raises: [Defect, AssertionError].} =
        return false

    blockStore2.hasBlock =
      proc(self: BlockStoreMock, cid: Cid): bool
          {.raises: [Defect, AssertionError].} =
        return false

    check not mgr.hasBlock(blk.cid)
