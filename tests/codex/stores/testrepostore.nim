import std/os
import std/strutils
import std/sequtils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/asynctest
import pkg/stew/byteutils
import pkg/stew/endians2
import pkg/datastore

import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/clock

import ../helpers
import ../helpers/mockclock
import ../examples
import ./commonstoretests

checksuite "Test RepoStore start/stop":

  var
    repoDs: Datastore
    metaDs: Datastore

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()

  test "Should set started flag once started":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200)
    await repo.start()
    check repo.started

  test "Should set started flag to false once stopped":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200)
    await repo.start()
    await repo.stop()
    check not repo.started

  test "Should allow start to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200)
    await repo.start()
    await repo.start()
    check repo.started

  test "Should allow stop to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200)
    await repo.stop()
    await repo.stop()
    check not repo.started

asyncchecksuite "RepoStore":
  var
    repoDs: Datastore
    metaDs: Datastore
    mockClock: MockClock

    repo: RepoStore

  let
    now: SecondsSince1970 = 123

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)

    repo = RepoStore.new(repoDs, metaDs, mockClock, quotaMaxBytes = 200)

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
    discard createTestBlock(100)

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

  proc queryMetaDs(key: Key): Future[seq[QueryResponse]] {.async.} =
    let
      query = Query.init(key)
      responseIter = (await metaDs.query(query)).tryGet
      response = (await allFinished(toSeq(responseIter)))
        .mapIt(it.read.tryGet)
        .filterIt(it.key.isSome)
    return response

  test "Should store block expiration timestamp":
    let
      duration = 10.seconds
      blk = createTestBlock(100)

    let
      expectedExpiration: SecondsSince1970 = 123 + 10
      expectedKey = Key.init("meta/ttl/" & $blk.cid).tryGet

    (await repo.putBlock(blk, duration.some)).tryGet

    let response = await queryMetaDs(expectedKey)

    check:
      response.len == 1
      !response[0].key == expectedKey
      response[0].data == expectedExpiration.toBytes

  test "Should store block with default expiration timestamp when not provided":
    let
      blk = createTestBlock(100)

    let
      expectedExpiration: SecondsSince1970 = 123 + DefaultBlockTtl.seconds
      expectedKey = Key.init("meta/ttl/" & $blk.cid).tryGet

    (await repo.putBlock(blk)).tryGet

    let response = await queryMetaDs(expectedKey)

    check:
      response.len == 1
      !response[0].key == expectedKey
      response[0].data == expectedExpiration.toBytes

  test "Should refuse update expiry with negative timestamp":
    let
      blk = createTestBlock(100)
      expectedExpiration: SecondsSince1970 = now + 10
      expectedKey = Key.init((BlocksTtlKey / $blk.cid).tryGet).tryGet

    (await repo.putBlock(blk, some 10.seconds)).tryGet

    var response = await queryMetaDs(expectedKey)

    check:
      response.len == 1
      !response[0].key == expectedKey
      response[0].data == expectedExpiration.toBytes

    expect ValueError:
      (await repo.ensureExpiry(blk.cid, -1)).tryGet

    expect ValueError:
      (await repo.ensureExpiry(blk.cid, 0)).tryGet

  test "Should fail when updating expiry of non-existing block":
    let
      blk = createTestBlock(100)

    expect DatastoreKeyNotFound:
      (await repo.ensureExpiry(blk.cid, 10)).tryGet

  test "Should update block expiration timestamp when new expiration is farther":
    let
      duration = 10
      blk = createTestBlock(100)
      expectedExpiration: SecondsSince1970 = now + duration
      updatedExpectedExpiration: SecondsSince1970 = expectedExpiration + 10
      expectedKey = Key.init((BlocksTtlKey / $blk.cid).tryGet).tryGet

    (await repo.putBlock(blk, some duration.seconds)).tryGet

    var response = await queryMetaDs(expectedKey)

    check:
      response.len == 1
      !response[0].key == expectedKey
      response[0].data == expectedExpiration.toBytes

    (await repo.ensureExpiry(blk.cid, updatedExpectedExpiration)).tryGet

    response = await queryMetaDs(expectedKey)

    check:
      response.len == 1
      !response[0].key == expectedKey
      response[0].data == updatedExpectedExpiration.toBytes

  test "Should not update block expiration timestamp when current expiration is farther then new one":
    let
      duration = 10
      blk = createTestBlock(100)
      expectedExpiration: SecondsSince1970 = now + duration
      updatedExpectedExpiration: SecondsSince1970 = expectedExpiration - 10
      expectedKey = Key.init((BlocksTtlKey / $blk.cid).tryGet).tryGet


    (await repo.putBlock(blk, some duration.seconds)).tryGet

    var response = await queryMetaDs(expectedKey)

    check:
      response.len == 1
      !response[0].key == expectedKey
      response[0].data == expectedExpiration.toBytes

    (await repo.ensureExpiry(blk.cid, updatedExpectedExpiration)).tryGet

    response = await queryMetaDs(expectedKey)

    check:
      response.len == 1
      !response[0].key == expectedKey
      response[0].data == expectedExpiration.toBytes

  test "delBlock should remove expiration metadata":
    let
      blk = createTestBlock(100)
      expectedKey = Key.init("meta/ttl/" & $blk.cid).tryGet

    (await repo.putBlock(blk, 10.seconds.some)).tryGet
    (await repo.delBlock(blk.cid)).tryGet

    let response = await queryMetaDs(expectedKey)

    check:
      response.len == 0

  test "Should retrieve block expiration information":
    proc unpack(beIter: Future[?!BlockExpirationIter]): Future[seq[BlockExpiration]] {.async.} =
      var expirations = newSeq[BlockExpiration](0)
      without iter =? (await beIter), err:
        return expirations
      for be in toSeq(iter):
        if value =? (await be):
          expirations.add(value)
      return expirations

    let
      duration = 10.seconds
      blk1 = createTestBlock(10)
      blk2 = createTestBlock(11)
      blk3 = createTestBlock(12)

    let
      expectedExpiration: SecondsSince1970 = 123 + 10

    proc assertExpiration(be: BlockExpiration, expectedBlock: bt.Block) =
      check:
        be.cid == expectedBlock.cid
        be.expiration == expectedExpiration


    (await repo.putBlock(blk1, duration.some)).tryGet
    (await repo.putBlock(blk2, duration.some)).tryGet
    (await repo.putBlock(blk3, duration.some)).tryGet

    let
      blockExpirations1 = await unpack(repo.getBlockExpirations(maxNumber=2, offset=0))
      blockExpirations2 = await unpack(repo.getBlockExpirations(maxNumber=2, offset=2))

    check blockExpirations1.len == 2
    assertExpiration(blockExpirations1[0], blk2)
    assertExpiration(blockExpirations1[1], blk1)

    check blockExpirations2.len == 1
    assertExpiration(blockExpirations2[0], blk3)

  test "should put empty blocks":
    let blk = Cid.example.emptyBlock
    check (await repo.putBlock(blk)).isOk

  test "should get empty blocks":
    let blk = Cid.example.emptyBlock

    let got = await repo.getBlock(blk.cid)
    check got.isOk
    check got.get.cid == blk.cid

  test "should delete empty blocks":
    let blk = Cid.example.emptyBlock
    check (await repo.delBlock(blk.cid)).isOk

  test "should have empty block":
    let blk = Cid.example.emptyBlock

    let has = await repo.hasBlock(blk.cid)
    check has.isOk
    check has.get

commonBlockStoreTests(
  "RepoStore Sql backend", proc: BlockStore =
    BlockStore(
      RepoStore.new(
        SQLiteDatastore.new(Memory).tryGet(),
        SQLiteDatastore.new(Memory).tryGet(),
        MockClock.new())))

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
        SQLiteDatastore.new(Memory).tryGet(),
        MockClock.new())),
  before = before,
  after = after)
