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
import pkg/chronos/futures
import pkg/chronicles
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/lrucache
import pkg/metrics
import pkg/questionable
import pkg/questionable/results
import pkg/datastore
import pkg/stew/endians2

import ./blockstore
import ./keyutils
import ./treereader
import ../blocktype
import ../clock
import ../systemclock
import ../merkletree
import ../utils

export blocktype, cid

logScope:
  topics = "codex repostore"

declareGauge(codexRepostoreBlocks, "codex repostore blocks")
declareGauge(codexRepostoreBytesUsed, "codex repostore bytes used")
declareGauge(codexRepostoreBytesReserved, "codex repostore bytes reserved")

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
    totalBlocks*: uint            # number of blocks in the store
    quotaMaxBytes*: uint          # maximum available bytes
    quotaUsedBytes*: uint         # bytes used by the repo
    quotaReservedBytes*: uint     # bytes reserved by the repo
    blockTtl*: Duration
    started*: bool
    treeReader*: TreeReader

  BlockExpiration* = object
    cid*: Cid
    expiration*: SecondsSince1970
  
proc updateMetrics(self: RepoStore) =
  codexRepostoreBlocks.set(self.totalBlocks.int64)
  codexRepostoreBytesUsed.set(self.quotaUsedBytes.int64)
  codexRepostoreBytesReserved.set(self.quotaReservedBytes.int64)

func totalUsed*(self: RepoStore): uint =
  (self.quotaUsedBytes + self.quotaReservedBytes)

func available*(self: RepoStore): uint =
  return self.quotaMaxBytes - self.totalUsed

func available*(self: RepoStore, bytes: uint): bool =
  return bytes < self.available()

proc encode(cidAndProof: (Cid, MerkleProof)): seq[byte] =
  let 
    (cid, proof) = cidAndProof
    cidBytes = cid.data.buffer
    proofBytes = proof.encode

  var buf = newSeq[byte](1 + cidBytes.len + proofBytes.len)

  buf[0] = cid.data.buffer.len.byte # cid shouldnt be more than 255 bytes?
  buf[1..cidBytes.len] = cidBytes
  buf[cidBytes.len + 1..^1] = proofBytes

  buf

proc decode(_: type (Cid, MerkleProof), data: seq[byte]): ?!(Cid, MerkleProof) =
  let cidLen = data[0].int

  let 
    cid = ? Cid.init(data[1..cidLen]).mapFailure
    proof = ? MerkleProof.decode(data[cidLen + 1..^1])
  
  success((cid, proof))

method putBlockCidAndProof*(
  self: RepoStore,
  treeCid: Cid,
  index: Natural,
  blockCid: Cid,
  proof: MerkleProof
): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  let value = (blockCid, proof).encode()

  await self.metaDs.put(key, value)

proc getCidAndProof(
  self: RepoStore,
  treeCid: Cid,
  index: Natural
): Future[?!(Cid, MerkleProof)] {.async.} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  without value =? await self.metaDs.get(key), err:
    if err of DatastoreKeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      return failure(err)

  return (Cid, MerkleProof).decode(value)

method getBlock*(self: RepoStore, cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the blockstore
  ##

  logScope:
    cid = cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return cid.emptyBlock

  without key =? makePrefixKey(self.postFixLen, cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  without data =? await self.repoDs.get(key), err:
    if not (err of DatastoreKeyNotFound):
      trace "Error getting block from datastore", err = err.msg, key
      return failure(err)

    return failure(newException(BlockNotFoundError, err.msg))

  trace "Got block for cid", cid
  return Block.new(cid, data, verify = true)


method getBlockAndProof*(self: RepoStore, treeCid: Cid, index: Natural): Future[?!(Block, MerkleProof)] {.async.} =
  without cidAndProof =? await self.getCidAndProof(treeCid, index), err:
    return failure(err)

  let (cid, proof) = cidAndProof

  without blk =? await self.getBlock(cid), err:
    return failure(err)

  success((blk, proof))

method getBlock*(self: RepoStore, treeCid: Cid, index: Natural): Future[?!Block] {.async.} =
  without cidAndProof =? await self.getCidAndProof(treeCid, index), err:
    return failure(err)

  await self.getBlock(cidAndProof[0])

method getBlock*(self: RepoStore, address: BlockAddress): Future[?!Block] =
  ## Get a block from the blockstore
  ##

  if address.leaf:
    self.getBlock(address.treeCid, address.index)
  else:
    self.getBlock(address.cid)

proc getBlockExpirationTimestamp(self: RepoStore, ttl: ?Duration): SecondsSince1970 =
  let duration = ttl |? self.blockTtl
  self.clock.now() + duration.seconds

proc getBlockExpirationEntry(
  self: RepoStore,
  batch: var seq[BatchEntry],
  cid: Cid,
  ttl: ?Duration): ?!BatchEntry =
  ## Get an expiration entry for a batch
  ##

  without key =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)

  let value = self.getBlockExpirationTimestamp(ttl).toBytes
  return success((key, value))

proc persistTotalBlocksCount(self: RepoStore): Future[?!void] {.async.} =
  if err =? (await self.metaDs.put(
      CodexTotalBlocksKey,
      @(self.totalBlocks.uint64.toBytesBE))).errorOption:
    trace "Error total blocks key!", err = err.msg
    return failure(err)
  return success()

method putBlock*(
  self: RepoStore,
  blk: Block,
  ttl = Duration.none): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  logScope:
    cid = blk.cid

  if blk.isEmpty:
    trace "Empty block, ignoring"
    return success()

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
  inc self.totalBlocks
  if isErr (await self.persistTotalBlocksCount()):
    trace "Unable to update block total metadata"
    return failure("Unable to update block total metadata")

  self.updateMetrics()
  return success()

proc updateQuotaBytesUsed(self: RepoStore, blk: Block): Future[?!void] {.async.} =
  let used = self.quotaUsedBytes - blk.data.len.uint
  if err =? (await self.metaDs.put(
      QuotaUsedKey,
      @(used.uint64.toBytesBE))).errorOption:
    trace "Error updating quota key!", err = err.msg
    return failure(err)
  self.quotaUsedBytes = used
  self.updateMetrics()
  return success()

proc removeBlockExpirationEntry(self: RepoStore, cid: Cid): Future[?!void] {.async.} =
  without key =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)
  return await self.metaDs.delete(key)

method delBlock*(self: RepoStore, cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the blockstore
  ##

  logScope:
    cid = cid

  trace "Deleting block"


  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success()

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

  dec self.totalBlocks
  if isErr (await self.persistTotalBlocksCount()):
    trace "Unable to update block total metadata"
    return failure("Unable to update block total metadata")

  self.updateMetrics()
  return success()

method delBlock*(self: RepoStore, treeCid: Cid, index: Natural): Future[?!void] {.async.} =
  without cid =? await self.treeReader.getBlockCid(treeCid, index), err:
    return failure(err)

  await self.delBlock(cid)

method hasBlock*(self: RepoStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  logScope:
    cid = cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success true

  without key =? makePrefixKey(self.postFixLen, cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  return await self.repoDs.has(key)

method hasBlock*(self: RepoStore, treeCid: Cid, index: Natural): Future[?!bool] {.async.} =
  without cidAndProof =? await self.getCidAndProof(treeCid, index), err:
    if err of BlockNotFoundError:
      return success(false)
    else:
      return failure(err)

  await self.hasBlock(cidAndProof[0])

method listBlocks*(
  self: RepoStore,
  blockType = BlockType.Manifest
): Future[?!AsyncIter[?Cid]] {.async.} =
  ## Get the list of blocks in the RepoStore.
  ## This is an intensive operation
  ##

  var
    iter = AsyncIter[?Cid]()

  let key =
    case blockType:
    of BlockType.Manifest: CodexManifestKey
    of BlockType.Block: CodexBlocksKey
    of BlockType.Both: CodexRepoKey

  let query = Query.init(key, value=false)
  without queryIter =? (await self.repoDs.query(query)), err:
    trace "Error querying cids in repo", blockType, err = err.msg
    return failure(err)

  proc next(): Future[?Cid] {.async.} =
    await idleAsync()
    if queryIter.finished:
      iter.finish
    else:
      if pair =? (await queryIter.next()) and cid =? pair.key:
        doAssert pair.data.len == 0
        trace "Retrieved record from repo", cid
        return Cid.init(cid.value).option
      else:
        return Cid.none

  iter.next = next
  return success iter

proc createBlockExpirationQuery(maxNumber: int, offset: int): ?!Query =
  let queryKey = ? createBlockExpirationMetadataQueryKey()
  success Query.init(queryKey, offset = offset, limit = maxNumber)

method getBlockExpirations*(
  self: RepoStore,
  maxNumber: int,
  offset: int): Future[?!AsyncIter[?BlockExpiration]] {.async, base.} =
  ## Get block expirations from the given RepoStore
  ##

  without query =? createBlockExpirationQuery(maxNumber, offset), err:
    trace "Unable to format block expirations query"
    return failure(err)

  without queryIter =? (await self.metaDs.query(query)), err:
    trace "Unable to execute block expirations query"
    return failure(err)

  var iter = AsyncIter[?BlockExpiration]()

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
    iter.finish
    return BlockExpiration.none

  iter.next = next
  return success iter

method close*(self: RepoStore): Future[void] {.async.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  (await self.repoDs.close()).expect("Should close datastore")

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
  self.updateMetrics()
  return success()

proc start*(self: RepoStore): Future[void] {.async.} =
  ## Start repo
  ##

  if self.started:
    trace "Repo already started"
    return

  trace "Starting repo"

  without total =? await self.metaDs.get(CodexTotalBlocksKey), err:
    if not (err of DatastoreKeyNotFound):
      error "Unable to read total number of blocks from metadata store", err = err.msg, key = $CodexTotalBlocksKey

  if total.len > 0:
    self.totalBlocks = uint64.fromBytesBE(total).uint
  trace "Number of blocks in store at start", total = self.totalBlocks

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

  self.updateMetrics()
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

proc new*(
    T: type RepoStore,
    repoDs: Datastore,
    metaDs: Datastore,
    clock: Clock = SystemClock.new(),
    postFixLen = 2,
    quotaMaxBytes = DefaultQuotaBytes,
    blockTtl = DefaultBlockTtl,
    treeCacheCapacity = DefaultTreeCacheCapacity
): RepoStore =
  ## Create new instance of a RepoStore
  ##
  let store = RepoStore(
    repoDs: repoDs,
    metaDs: metaDs,
    clock: clock,
    postFixLen: postFixLen,
    quotaMaxBytes: quotaMaxBytes,
    blockTtl: blockTtl)

  proc getBlockFromStore(cid: Cid): Future[?!Block] = store.getBlock(cid)
  store.treeReader = TreeReader.new(getBlockFromStore, treeCacheCapacity)
  store
