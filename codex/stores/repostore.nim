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
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/lrucache
import pkg/metrics
import pkg/questionable
import pkg/questionable/results
import pkg/datastore
import pkg/stew/endians2

import ./blockstore
import ./keyutils
import ../blocktype
import ../clock
import ../systemclock
import ../logutils
import ../merkletree
import ../utils

export blocktype, cid

logScope:
  topics = "codex repostore"

declareGauge(codex_repostore_blocks, "codex repostore blocks")
declareGauge(codex_repostore_bytes_used, "codex repostore bytes used")
declareGauge(codex_repostore_bytes_reserved, "codex repostore bytes reserved")

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

  BlockExpiration* = object
    cid*: Cid
    expiration*: SecondsSince1970

proc updateMetrics(self: RepoStore) =
  codex_repostore_blocks.set(self.totalBlocks.int64)
  codex_repostore_bytes_used.set(self.quotaUsedBytes.int64)
  codex_repostore_bytes_reserved.set(self.quotaReservedBytes.int64)

func totalUsed*(self: RepoStore): uint =
  (self.quotaUsedBytes + self.quotaReservedBytes)

func available*(self: RepoStore): uint =
  return self.quotaMaxBytes - self.totalUsed

func available*(self: RepoStore, bytes: uint): bool =
  return bytes < self.available()

proc encode(cidAndProof: (Cid, CodexProof)): seq[byte] =
  ## Encodes a tuple of cid and merkle proof in a following format:
  ## | 8-bytes | n-bytes | remaining bytes |
  ## |    n    |   cid   |      proof      |
  ##
  ## where n is a size of cid
  ##
  let
    (cid, proof) = cidAndProof
    cidBytes = cid.data.buffer
    proofBytes = proof.encode
    n = cidBytes.len
    nBytes = n.uint64.toBytesBE

  @nBytes & cidBytes & proofBytes

proc decode(_: type (Cid, CodexProof), data: seq[byte]): ?!(Cid, CodexProof) =
  let
    n = uint64.fromBytesBE(data[0..<sizeof(uint64)]).int
    cid = ? Cid.init(data[sizeof(uint64)..<sizeof(uint64) + n]).mapFailure
    proof = ? CodexProof.decode(data[sizeof(uint64) + n..^1])
  success((cid, proof))

proc decodeCid(_: type (Cid, CodexProof), data: seq[byte]): ?!Cid =
  let
    n = uint64.fromBytesBE(data[0..<sizeof(uint64)]).int
    cid = ? Cid.init(data[sizeof(uint64)..<sizeof(uint64) + n]).mapFailure
  success(cid)

method putCidAndProof*(
  self: RepoStore,
  treeCid: Cid,
  index: Natural,
  blockCid: Cid,
  proof: CodexProof
): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  trace "Storing block cid and proof", blockCid, key

  let value = (blockCid, proof).encode()

  await self.metaDs.put(key, value)

method getCidAndProof*(
  self: RepoStore,
  treeCid: Cid,
  index: Natural): Future[?!(Cid, CodexProof)] {.async.} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  without value =? await self.metaDs.get(key), err:
    if err of DatastoreKeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      return failure(err)

  without (cid, proof) =? (Cid, CodexProof).decode(value), err:
    trace "Unable to decode cid and proof", err = err.msg
    return failure(err)

  trace "Got cid and proof for block", cid, proof = $proof
  return success (cid, proof)

method getCid*(
  self: RepoStore,
  treeCid: Cid,
  index: Natural): Future[?!Cid] {.async.} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  without value =? await self.metaDs.get(key), err:
    if err of DatastoreKeyNotFound:
      trace "Cid not found", treeCid, index
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      trace "Error getting cid from datastore", err = err.msg, key
      return failure(err)

  return (Cid, CodexProof).decodeCid(value)

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


method getBlockAndProof*(self: RepoStore, treeCid: Cid, index: Natural): Future[?!(Block, CodexProof)] {.async.} =
  without cidAndProof =? await self.getCidAndProof(treeCid, index), err:
    return failure(err)

  let (cid, proof) = cidAndProof

  without blk =? await self.getBlock(cid), err:
    return failure(err)

  success((blk, proof))

method getBlock*(self: RepoStore, treeCid: Cid, index: Natural): Future[?!Block] {.async.} =
  without cid =? await self.getCid(treeCid, index), err:
    return failure(err)

  await self.getBlock(cid)

method getBlock*(self: RepoStore, address: BlockAddress): Future[?!Block] =
  ## Get a block from the blockstore
  ##

  if address.leaf:
    self.getBlock(address.treeCid, address.index)
  else:
    self.getBlock(address.cid)

proc getBlockExpirationEntry(
  self: RepoStore,
  cid: Cid,
  ttl: SecondsSince1970): ?!BatchEntry =
  ## Get an expiration entry for a batch with timestamp
  ##

  without key =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)

  return success((key, ttl.toBytes))

proc getBlockExpirationEntry(
  self: RepoStore,
  cid: Cid,
  ttl: ?Duration): ?!BatchEntry =
  ## Get an expiration entry for a batch for duration since "now"
  ##

  let duration = ttl |? self.blockTtl
  self.getBlockExpirationEntry(cid, self.clock.now() + duration.seconds)

method ensureExpiry*(
    self: RepoStore,
    cid: Cid,
    expiry: SecondsSince1970
): Future[?!void] {.async.} =
  ## Ensure that block's associated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##

  logScope:
    cid = cid

  if expiry <= 0:
    return failure(newException(ValueError, "Expiry timestamp must be larger then zero"))

  without expiryKey =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)

  without currentExpiry =? await self.metaDs.get(expiryKey), err:
    if err of DatastoreKeyNotFound:
      error "No current expiry exists for the block"
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      error "Could not read datastore key", err = err.msg
      return failure(err)

  logScope:
    current = currentExpiry.toSecondsSince1970
    ensuring = expiry

  if expiry <= currentExpiry.toSecondsSince1970:
    trace "Expiry is larger than or equal to requested"
    return success()

  if err =? (await self.metaDs.put(expiryKey, expiry.toBytes)).errorOption:
    trace "Error updating expiration metadata entry", err = err.msg
    return failure(err)

  return success()

method ensureExpiry*(
    self: RepoStore,
    treeCid: Cid,
    index: Natural,
    expiry: SecondsSince1970
): Future[?!void] {.async.} =
  ## Ensure that block's associated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##
  without cidAndProof =? await self.getCidAndProof(treeCid, index), err:
    return failure(err)

  await self.ensureExpiry(cidAndProof[0], expiry)

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
    warn "Error getting key from provider", err = err.msg
    return failure(err)

  if await key in self.repoDs:
    trace "Block already in store", cid = blk.cid
    return success()

  if (self.totalUsed + blk.data.len.uint) > self.quotaMaxBytes:
    error "Cannot store block, quota used!", used = self.totalUsed
    return failure(
      newException(QuotaUsedError, "Cannot store block, quota used!"))

  var
    batch: seq[BatchEntry]

  let
    used = self.quotaUsedBytes + blk.data.len.uint

  if err =? (await self.repoDs.put(key, blk.data)).errorOption:
    error "Error storing block", err = err.msg
    return failure(err)

  batch.add((QuotaUsedKey, @(used.uint64.toBytesBE)))

  without blockExpEntry =? self.getBlockExpirationEntry(blk.cid, ttl), err:
    warn "Unable to create block expiration metadata key", err = err.msg
    return failure(err)
  batch.add(blockExpEntry)

  if err =? (await self.metaDs.put(batch)).errorOption:
    error "Error updating quota bytes", err = err.msg

    if err =? (await self.repoDs.delete(key)).errorOption:
      error "Error deleting block after failed quota update", err = err.msg
      return failure(err)

    return failure(err)

  self.quotaUsedBytes = used
  inc self.totalBlocks
  if isErr (await self.persistTotalBlocksCount()):
    warn "Unable to update block total metadata"
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
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  trace "Fetching proof", key
  without value =? await self.metaDs.get(key), err:
    if err of DatastoreKeyNotFound:
      return success()
    else:
      return failure(err)

  without cid =? (Cid, CodexProof).decodeCid(value), err:
    return failure(err)

  trace "Deleting block", cid
  if err =? (await self.delBlock(cid)).errorOption:
    return failure(err)

  await self.metaDs.delete(key)

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
  without cid =? await self.getCid(treeCid, index), err:
    if err of BlockNotFoundError:
      return success(false)
    else:
      return failure(err)

  await self.hasBlock(cid)

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

  trace "Closing repostore"

  if not self.metaDs.isNil:
    (await self.metaDs.close()).expect("Should meta datastore")

  if not self.repoDs.isNil:
    (await self.repoDs.close()).expect("Should repo datastore")

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
  await self.close()

  self.started = false

func new*(
    T: type RepoStore,
    repoDs: Datastore,
    metaDs: Datastore,
    clock: Clock = SystemClock.new(),
    postFixLen = 2,
    quotaMaxBytes = DefaultQuotaBytes,
    blockTtl = DefaultBlockTtl
): RepoStore =
  ## Create new instance of a RepoStore
  ##
  RepoStore(
    repoDs: repoDs,
    metaDs: metaDs,
    clock: clock,
    postFixLen: postFixLen,
    quotaMaxBytes: quotaMaxBytes,
    blockTtl: blockTtl
  )
