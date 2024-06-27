import std/os
import std/strutils
import std/sequtils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/stew/byteutils
import pkg/stew/endians2
import pkg/datastore

import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/utils/asynciter

import ../../asynctest
import ../helpers
import ../examples
import ./commonstoretests

import ./repostore/testcoders

checksuite "Test RepoStore start/stop":

  var
    repoDs: Datastore
    metaDs: Datastore

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()

  test "Should set started flag once started":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    check repo.started

  test "Should set started flag to false once stopped":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.stop()
    check not repo.started

  test "Should allow start to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.start()
    check repo.started

  test "Should allow stop to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.stop()
    await repo.stop()
    check not repo.started

asyncchecksuite "RepoStore":
  var
    repoDs: Datastore
    metaDs: Datastore
    repo: RepoStore

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()

    repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet

  proc createTestBlock(size: int): bt.Block =
    bt.Block.new('a'.repeat(size).toBytes).tryGet()

  test "Should update current used bytes on block put":
    let blk = createTestBlock(200)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet

    check:
      repo.quotaUsedBytes == 200'nb

  test "Should update current used bytes on block delete":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

    (await repo.delBlock(blk.cid)).tryGet

    check:
      repo.quotaUsedBytes == 0'nb

  test "Should not update current used bytes if block exist":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

    # put again
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

  test "Should fail storing passed the quota":
    let blk = createTestBlock(300)

    check repo.totalUsed == 0'nb
    expect QuotaNotEnoughError:
      (await repo.putBlock(blk)).tryGet

  test "Should reserve bytes":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.totalUsed == 100'nb

    (await repo.reserve(100'nb)).tryGet

    check:
      repo.totalUsed == 200'nb
      repo.quotaUsedBytes == 100'nb
      repo.quotaReservedBytes == 100'nb

  test "Should not reserve bytes over max quota":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.totalUsed == 100'nb

    expect QuotaNotEnoughError:
      (await repo.reserve(101'nb)).tryGet

    check:
      repo.totalUsed == 100'nb
      repo.quotaUsedBytes == 100'nb
      repo.quotaReservedBytes == 0'nb

  test "Should release bytes":
    discard createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.reserve(100'nb)).tryGet
    check repo.totalUsed == 100'nb

    (await repo.release(100'nb)).tryGet

    check:
      repo.totalUsed == 0'nb
      repo.quotaUsedBytes == 0'nb
      repo.quotaReservedBytes == 0'nb

  test "Should not release bytes less than quota":
    check repo.totalUsed == 0'nb
    (await repo.reserve(100'nb)).tryGet
    check repo.totalUsed == 100'nb

    expect RangeDefect:
      (await repo.release(101'nb)).tryGet

    check:
      repo.totalUsed == 100'nb
      repo.quotaUsedBytes == 0'nb
      repo.quotaReservedBytes == 100'nb

  test "should put empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()
    check (await repo.putBlock(blk)).isOk

  test "should get empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()

    let got = await repo.getBlock(blk.cid)
    check got.isOk
    check got.get.cid == blk.cid

  test "should delete empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()
    check (await repo.delBlock(blk.cid)).isOk

  test "should have empty block":
    let blk = Cid.example.emptyBlock.tryGet()

    let has = await repo.hasBlock(blk.cid)
    check has.isOk
    check has.get

commonBlockStoreTests(
  "RepoStore Sql backend", proc: BlockStore =
    BlockStore(
      RepoStore.new(
        SQLiteDatastore.new(Memory).tryGet(),
        SQLiteDatastore.new(Memory).tryGet())))

const
  path = currentSourcePath().parentDir / "test"

proc before() {.async.} =
  createDir(path)

proc after() {.async.} =
  removeDir(path)

let
  depth = path.split(DirSep).len

commonBlockStoreTests(
  "RepoStore FS backend", proc: BlockStore =
    BlockStore(
      RepoStore.new(
        FSDatastore.new(path, depth).tryGet(),
        SQLiteDatastore.new(Memory).tryGet())),
  before = before,
  after = after)
