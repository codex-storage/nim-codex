import std/os
import std/options
import std/strutils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/stew/byteutils
import pkg/stew/endians2
import pkg/datastore

import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/clock

import ../helpers
import ./commonstoretests

suite "Test RepoStore Quota":

  var
    repoDs: Datastore
    metaDs: Datastore

    repo: RepoStore

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()

    repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet

  proc createTestBlock(size: int): bt.Block =
    bt.Block.new('a'.repeat(size).toBytes).tryGet()

  test "Should update current used bytes on block put":
    let blk = createTestBlock(200)

    check repo.quotaUsedBytes == 0
    (await repo.putBlock(blk)).tryGet

    check:
      repo.quotaUsedBytes == 200
      uint64.fromBytesBE((await metaDs.get(QuotaUsedKey)).tryGet) == 200'u

  test "Should update current used bytes on block delete":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100

    (await repo.delBlock(blk.cid)).tryGet

    check:
      repo.quotaUsedBytes == 0
      uint64.fromBytesBE((await metaDs.get(QuotaUsedKey)).tryGet) == 0'u

  test "Should not update current used bytes if block exist":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100

    # put again
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100

    check:
      uint64.fromBytesBE((await metaDs.get(QuotaUsedKey)).tryGet) == 100'u

  test "Should fail storing passed the quota":
    let blk = createTestBlock(300)

    check repo.totalUsed == 0
    expect QuotaUsedError:
      (await repo.putBlock(blk)).tryGet

  test "Should reserve bytes":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0
    (await repo.putBlock(blk)).tryGet
    check repo.totalUsed == 100

    (await repo.reserve(100)).tryGet

    check:
      repo.totalUsed == 200
      repo.quotaUsedBytes == 100
      repo.quotaReservedBytes == 100
      uint64.fromBytesBE((await metaDs.get(QuotaReservedKey)).tryGet) == 100'u

  test "Should not reserve bytes over max quota":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0
    (await repo.putBlock(blk)).tryGet
    check repo.totalUsed == 100

    expect QuotaNotEnoughError:
      (await repo.reserve(101)).tryGet

    check:
      repo.totalUsed == 100
      repo.quotaUsedBytes == 100
      repo.quotaReservedBytes == 0

    expect DatastoreKeyNotFound:
      discard (await metaDs.get(QuotaReservedKey)).tryGet

  test "Should release bytes":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0
    (await repo.reserve(100)).tryGet
    check repo.totalUsed == 100

    (await repo.release(100)).tryGet

    check:
      repo.totalUsed == 0
      repo.quotaUsedBytes == 0
      repo.quotaReservedBytes == 0
      uint64.fromBytesBE((await metaDs.get(QuotaReservedKey)).tryGet) == 0'u

  test "Should not release bytes less than quota":
    check repo.totalUsed == 0
    (await repo.reserve(100)).tryGet
    check repo.totalUsed == 100

    expect CatchableError:
      (await repo.release(101)).tryGet

    check:
      repo.totalUsed == 100
      repo.quotaUsedBytes == 0
      repo.quotaReservedBytes == 100
      uint64.fromBytesBE((await metaDs.get(QuotaReservedKey)).tryGet) == 100'u

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
