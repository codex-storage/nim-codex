## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/datastore
import pkg/stew/endians2

import ./blockstore
import ./keyutils
import ../blocktype
import ../clock
import ../systemclock

export blocktype, libp2p

logScope:
  topics = "codex repostore"

const
  DefaultBlockTtl* = 24.hours
  DefaultQuotaBytes* = 1'u shl 33'u # ~8GB

type
  QuotaUsedError* = object of CodexError
  QuotaNotEnoughError* = object of CodexError

  RepoStore* = ref object of BlockStore
    postFixLen*: int
    repoDs*: Datastore
    metaDs*: Datastore
    clock: Clock
    quotaMaxBytes*: uint
    quotaUsedBytes*: uint
    quotaReservedBytes*: uint
    blockTtl*: Duration
    started*: bool

  BlockExpiration* = object
    cid*: Cid
    expiration*: SecondsSince1970
  GetNext = proc(): Future[?BlockExpiration] {.upraises: [], gcsafe, closure.}
  BlockExpirationIter* = ref object
    finished*: bool
    next*: GetNext

iterator items*(q: BlockExpirationIter): Future[?BlockExpiration] =
  while not q.finished:
    yield q.next()

func totalUsed*(self: RepoStore): uint =
  (self.quotaUsedBytes + self.quotaReservedBytes)

method getBlock*(self: RepoStore, cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the blockstore
  ##

  without key =? makePrefixKey(self.postFixLen, cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  without data =? await self.repoDs.get(key), err:
    if not (err of DatastoreKeyNotFound):
      trace "Error getting block from datastore", err = err.msg, key
      return failure(err)

    return failure(newException(BlockNotFoundError, err.msg))

  trace "Got block for cid", cid
  return Block.new(cid, data)

proc getBlockExpirationTimestamp(self: RepoStore, ttl: ?Duration): SecondsSince1970 =
  let duration = ttl |? self.blockTtl
  self.clock.now() + duration.seconds

proc getBlockExpirationEntry(self: RepoStore, batch: var seq[BatchEntry], cid: Cid, ttl: ?Duration): ?!BatchEntry =
  without key =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)

  let value = self.getBlockExpirationTimestamp(ttl).toBytes
  return success((key, value))

method putBlock*(
  self: RepoStore,
  blk: Block,
  ttl = Duration.none): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  without key =? makePrefixKey(self.postFixLen, blk.cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  if await key in self.repoDs:
    trace "Block already in store", cid = blk.cid
    return success()

  if (self.totalUsed + blk.data.len.uint) > self.quotaMaxBytes:
    error "Cannot store block, quota used!", used = self.totalUsed
    return failure(
      newException(QuotaUsedError, "Cannot store block, quota used!"))

  trace "Storing block with key", key

  var
    batch: seq[BatchEntry]

  let
    used = self.quotaUsedBytes + blk.data.len.uint

  if err =? (await self.repoDs.put(key, blk.data)).errorOption:
    trace "Error storing block", err = err.msg
    return failure(err)

  trace "Updating quota", used
  batch.add((QuotaUsedKey, @(used.uint64.toBytesBE)))

  without blockExpEntry =? self.getBlockExpirationEntry(batch, blk.cid, ttl), err:
    trace "Unable to create block expiration metadata key", err = err.msg
    return failure(err)
  batch.add(blockExpEntry)

  if err =? (await self.metaDs.put(batch)).errorOption:
    trace "Error updating quota bytes", err = err.msg

    if err =? (await self.repoDs.delete(key)).errorOption:
      trace "Error deleting block after failed quota update", err = err.msg
      return failure(err)

    return failure(err)

  self.quotaUsedBytes = used
  return success()

proc updateQuotaBytesUsed(self: RepoStore, blk: Block): Future[?!void] {.async.} =
  let used = self.quotaUsedBytes - blk.data.len.uint
  if err =? (await self.metaDs.put(
      QuotaUsedKey,
      @(used.uint64.toBytesBE))).errorOption:
    trace "Error updating quota key!", err = err.msg
    return failure(err)
  self.quotaUsedBytes = used
  return success()

proc removeBlockExpirationEntry(self: RepoStore, cid: Cid): Future[?!void] {.async.} =
  without key =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)
  return await self.metaDs.delete(key)

method delBlock*(self: RepoStore, cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block", cid

  if blk =? (await self.getBlock(cid)):
    if key =? makePrefixKey(self.postFixLen, cid) and
      err =? (await self.repoDs.delete(key)).errorOption:
      trace "Error deleting block!", err = err.msg
      return failure(err)

    if isErr (await self.updateQuotaBytesUsed(blk)):
      trace "Unable to update quote-bytes-used in metadata store"
      return failure("Unable to update quote-bytes-used in metadata store")

    if isErr (await self.removeBlockExpirationEntry(blk.cid)):
      trace "Unable to remove block expiration entry from metadata store"
      return failure("Unable to remove block expiration entry from metadata store")

    trace "Deleted block", cid, totalUsed = self.totalUsed

  return success()

method hasBlock*(self: RepoStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  without key =? makePrefixKey(self.postFixLen, cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  return await self.repoDs.has(key)

method listBlocks*(
  self: RepoStore,
  blockType = BlockType.Manifest): Future[?!BlocksIter] {.async.} =
  ## Get the list of blocks in the RepoStore.
  ## This is an intensive operation
  ##

  var
    iter = BlocksIter()

  let key =
    case blockType:
    of BlockType.Manifest: CodexManifestKey
    of BlockType.Block: CodexBlocksKey
    of BlockType.Both: CodexRepoKey

  without queryIter =? (await self.repoDs.query(Query.init(key))), err:
    trace "Error querying cids in repo", blockType, err = err.msg
    return failure(err)

  proc next(): Future[?Cid] {.async.} =
    await idleAsync()
    iter.finished = queryIter.finished
    if not queryIter.finished:
      if pair =? (await queryIter.next()) and cid =? pair.key:
        trace "Retrieved record from repo", cid
        return Cid.init(cid.value).option

    return Cid.none

  iter.next = next
  return success iter

proc createBlockExpirationQuery(maxNumber: int, offset: int): ?!Query =
  let queryKey = ? createBlockExpirationMetadataQueryKey()
  success Query.init(queryKey, offset = offset, limit = maxNumber)

method getBlockExpirations*(self: RepoStore, maxNumber: int, offset: int): Future[?!BlockExpirationIter] {.async, base.} =
  without query =? createBlockExpirationQuery(maxNumber, offset), err:
    trace "Unable to format block expirations query"
    return failure(err)

  without queryIter =? (await self.metaDs.query(query)), err:
    trace "Unable to execute block expirations query"
    return failure(err)

  var iter = BlockExpirationIter()

  proc next(): Future[?BlockExpiration] {.async.} =
    if not queryIter.finished:
      if pair =? (await queryIter.next()) and blockKey =? pair.key:
        let expirationTimestamp = pair.data
        let cidResult = Cid.init(blockKey.value)
        if not cidResult.isOk:
          raiseAssert("Unable to parse CID from blockKey.value: " & blockKey.value & $cidResult.error)
        return BlockExpiration(
          cid: cidResult.get,
          expiration: expirationTimestamp.toSecondsSince1970
        ).some
    else:
      discard await queryIter.dispose()
    iter.finished = true
    return BlockExpiration.none

  iter.next = next
  return success iter

method close*(self: RepoStore): Future[void] {.async.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  (await self.repoDs.close()).expect("Should close datastore")

proc hasBlock*(self: RepoStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore.
  ## Return false if error encountered
  ##

  without key =? makePrefixKey(self.postFixLen, cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err.msg)

  return await self.repoDs.has(key)

proc reserve*(self: RepoStore, bytes: uint): Future[?!void] {.async.} =
  ## Reserve bytes
  ##

  trace "Reserving bytes", reserved = self.quotaReservedBytes, bytes

  if (self.totalUsed + bytes) > self.quotaMaxBytes:
    trace "Not enough storage quota to reserver", reserve = self.totalUsed + bytes
    return failure(
      newException(QuotaNotEnoughError, "Not enough storage quota to reserver"))

  self.quotaReservedBytes += bytes
  if err =? (await self.metaDs.put(
    QuotaReservedKey,
    @(toBytesBE(self.quotaReservedBytes.uint64)))).errorOption:

    trace "Error reserving bytes", err = err.msg

    self.quotaReservedBytes += bytes
    return failure(err)

  return success()

proc release*(self: RepoStore, bytes: uint): Future[?!void] {.async.} =
  ## Release bytes
  ##

  trace "Releasing bytes", reserved = self.quotaReservedBytes, bytes

  if (self.quotaReservedBytes.int - bytes.int) < 0:
    trace "Cannot release this many bytes",
      quotaReservedBytes = self.quotaReservedBytes, bytes

    return failure("Cannot release this many bytes")

  self.quotaReservedBytes -= bytes
  if err =? (await self.metaDs.put(
    QuotaReservedKey,
    @(toBytesBE(self.quotaReservedBytes.uint64)))).errorOption:

    trace "Error releasing bytes", err = err.msg

    self.quotaReservedBytes -= bytes

    return failure(err)

  trace "Released bytes", bytes
  return success()

proc start*(self: RepoStore): Future[void] {.async.} =
  ## Start repo
  ##

  if self.started:
    trace "Repo already started"
    return

  trace "Starting repo"

  ## load current persist and cache bytes from meta ds
  without quotaUsedBytes =? await self.metaDs.get(QuotaUsedKey), err:
    if not (err of DatastoreKeyNotFound):
      error "Error getting cache bytes from datastore",
        err = err.msg, key = $QuotaUsedKey

      raise newException(Defect, err.msg)

  if quotaUsedBytes.len > 0:
    self.quotaUsedBytes = uint64.fromBytesBE(quotaUsedBytes).uint

  notice "Current bytes used for cache quota", bytes = self.quotaUsedBytes

  without quotaReservedBytes =? await self.metaDs.get(QuotaReservedKey), err:
    if not (err of DatastoreKeyNotFound):
      error "Error getting persist bytes from datastore",
        err = err.msg, key = $QuotaReservedKey

      raise newException(Defect, err.msg)

  if quotaReservedBytes.len > 0:
    self.quotaReservedBytes = uint64.fromBytesBE(quotaReservedBytes).uint

  if self.quotaUsedBytes > self.quotaMaxBytes:
    raiseAssert "All storage quota used, increase storage quota!"

  notice "Current bytes used for persist quota", bytes = self.quotaReservedBytes

  self.started = true

proc stop*(self: RepoStore): Future[void] {.async.} =
  ## Stop repo
  ##

  if not self.started:
    trace "Repo is not started"
    return

  trace "Stopping repo"
  (await self.repoDs.close()).expect("Should close repo store!")
  (await self.metaDs.close()).expect("Should close meta store!")

  self.started = false

func new*(
  T: type RepoStore,
  repoDs: Datastore,
  metaDs: Datastore,
  clock: Clock = SystemClock.new(),
  postFixLen = 2,
  quotaMaxBytes = DefaultQuotaBytes,
  blockTtl = DefaultBlockTtl): T =
  T(
    repoDs: repoDs,
    metaDs: metaDs,
    clock: clock,
    postFixLen: postFixLen,
    quotaMaxBytes: quotaMaxBytes,
    blockTtl: blockTtl)
