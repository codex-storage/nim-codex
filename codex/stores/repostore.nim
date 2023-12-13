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

import std/sugar

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
import ./typeddatastore
import ../blocktype
import ../clock
import ../systemclock
import ../logutils
import ../merkletree
import ../utils
import ../utils/genericcoders

export blocktype, cid

logScope:
  topics = "codex repostore"

declareGauge(codex_repostore_blocks, "codex repostore blocks")
declareGauge(codex_repostore_bytes_used, "codex repostore bytes used")
declareGauge(codex_repostore_bytes_reserved, "codex repostore bytes reserved")

const
  DefaultBlockTtl* = 24.hours
  DefaultQuotaBytes* = 8.GiBs

type
  QuotaNotEnoughError* = object of CodexError

  RepoStore* = ref object of BlockStore
    postFixLen*: int
    repoDs*: Datastore
    metaDs*: Datastore
    clock: Clock
    quotaMaxBytes*: NBytes
    quotaUsage*: QuotaUsage
    totalBlocks*: Natural
    blockTtl*: Duration
    started*: bool

  QuotaUsage* = object
    used: NBytes
    reserved: NBytes

  BlockMetadata* = object
    expiry*: SecondsSince1970
    size*: NBytes
    refCount*: Natural

  LeafMetadata* = object
    blkCid: Cid
    proof: CodexProof

  BlockExpiration* = object
    cid*: Cid
    expiry*: SecondsSince1970

func quotaUsedBytes*(self: RepoStore): NBytes =
  self.quotaUsage.used

func quotaReservedBytes*(self: RepoStore): NBytes =
  self.quotaUsage.reserved

func totalUsed*(self: RepoStore): NBytes =
  (self.quotaUsedBytes + self.quotaReservedBytes)

func available*(self: RepoStore): NBytes =
  return self.quotaMaxBytes - self.totalUsed

func available*(self: RepoStore, bytes: NBytes): bool =
  return bytes < self.available()

proc encode(t: Cid): seq[byte] = t.data.buffer
proc decode(T: type Cid, bytes: seq[byte]): ?!Cid = Cid.init(bytes).mapFailure

proc encode(t: QuotaUsage): seq[byte] = t.autoencode
proc decode(T: type QuotaUsage, bytes: seq[byte]): ?!T = T.autodecode(bytes)

proc encode(t: BlockMetadata): seq[byte] = t.autoencode
proc decode(T: type BlockMetadata, bytes: seq[byte]): ?!T = T.autodecode(bytes)

proc encode(t: LeafMetadata): seq[byte] = t.autoencode
proc decode(T: type LeafMetadata, bytes: seq[byte]): ?!T = T.autodecode(bytes)

###########################################################
# Helper types and procs
###########################################################

type
  DeleteResultKind = enum
    Deleted = 0,    # block removed from store
    InUse = 1,      # block not removed, refCount > 0 and not expired
    NotFound = 2    # block not found in store

  DeleteResult = object
    kind: DeleteResultKind
    released: NBytes

  StoreResultKind = enum
    Stored = 0,         # new block stored
    AlreadyInStore = 1  # block already in store

  StoreResult = object
    kind: StoreResultKind
    used: NBytes

proc encode(t: DeleteResult): seq[byte] = t.autoencode
proc decode(T: type DeleteResult, bytes: seq[byte]): ?!T = T.autodecode(bytes)

proc encode(t: StoreResult): seq[byte] = t.autoencode
proc decode(T: type StoreResult, bytes: seq[byte]): ?!T = T.autodecode(bytes)

proc putLeafMetadata(self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid, proof: CodexProof): Future[?!StoreResultKind] {.async.} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  await self.metaDs.modifyTGetU(key,
    proc (maybeCurrMd: ?LeafMetadata): Future[(?LeafMetadata, StoreResultKind)] {.async.} =
      var
        md: LeafMetadata
        res: StoreResultKind

      if currMd =? maybeCurrMd:
        md = currMd
        res = AlreadyInStore
      else:
        md = LeafMetadata(blkCid: blkCid, proof: proof)
        res = Stored

      (md.some, res)
  )

proc getLeafMetadata(self: RepoStore, treeCid: Cid, index: Natural): Future[?!LeafMetadata] {.async.} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  without leafMd =? await self.metaDs.get(key), err:
    if err of DatastoreKeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      return failure(err)

  LeafMetadata.decode(leafMd)

proc updateTotalBlocksCount(self: RepoStore, plusCount: Natural = 0, minusCount: Natural = 0): Future[?!void] {.async.} =
  await self.metaDs.modifyT(CodexTotalBlocksKey,
    proc (maybeCurrCount: ?Natural): Future[?Natural] {.async.} =
      let count: Natural =
        if currCount =? maybeCurrCount:
          currCount + plusCount - minusCount
        else:
          plusCount - minusCount

      self.totalBlocks = count
      codex_repostore_blocks.set(count.int64)
      count.some
  )

proc updateQuotaUsage(
  self: RepoStore,
  plusUsed: NBytes = 0.NBytes,
  minusUsed: NBytes = 0.NBytes,
  plusReserved: NBytes = 0.NBytes,
  minusReserved: NBytes = 0.NBytes
): Future[?!void] {.async.} =
  await self.metaDs.modifyT(QuotaUsedKey,
    proc (maybeCurrUsage: ?QuotaUsage): Future[?QuotaUsage] {.async.} =
      var usage: QuotaUsage

      if currUsage =? maybeCurrUsage:
        usage = QuotaUsage(used: currUsage.used + plusUsed - minusUsed, reserved: currUsage.reserved + plusReserved - minusReserved)
      else:
        usage = QuotaUsage(used: plusUsed - minusUsed, reserved: plusReserved - minusReserved)

      if usage.used + usage.reserved > self.quotaMaxBytes:
        raise newException(QuotaNotEnoughError,
          "Quota usage would exceed the limit. Used: " & $usage.used & ", reserved: " &
            $usage.reserved & ", limit: " & $self.quotaMaxBytes)
      else:
        self.quotaUsage = usage
        codex_repostore_bytes_used.set(usage.used.int64)
        codex_repostore_bytes_reserved.set(usage.reserved.int64)
        return usage.some
  )

proc updateBlockMetadata(
  self: RepoStore,
  cid: Cid,
  plusRefCount: Natural = 0,
  minusRefCount: Natural = 0,
  minExpiry: SecondsSince1970 = 0
): Future[?!void] {.async.} =
  if cid.isEmpty:
    return success()

  without metaKey =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)

  await self.metaDs.modifyT(metaKey,
    proc (maybeCurrBlockMd: ?BlockMetadata): Future[?BlockMetadata] {.async.} =
      if currBlockMd =? maybeCurrBlockMd:
        BlockMetadata(
          size: currBlockMd.size,
          expiry: max(currBlockMd.expiry, minExpiry),
          refCount: currBlockMd.refCount + plusRefCount - minusRefCount
        ).some
      else:
        raise newException(BlockNotFoundError, "Metadata for block with cid " & $cid & " not found")
  )

proc storeBlock(self: RepoStore, blk: Block, minExpiry: SecondsSince1970): Future[?!StoreResult] {.async.} =
  if blk.isEmpty:
    return success(StoreResult(kind: AlreadyInStore))

  without metaKey =? createBlockExpirationMetadataKey(blk.cid), err:
    return failure(err)

  without blkKey =? makePrefixKey(self.postFixLen, blk.cid), err:
    return failure(err)

  await self.metaDs.modifyTGetU(metaKey,
    proc (maybeCurrMd: ?BlockMetadata): Future[(?BlockMetadata, StoreResult)] {.async.} =
      var
        md: BlockMetadata
        res: StoreResult

      if currMd =? maybeCurrMd:
        if currMd.size == blk.data.len.NBytes:
          md = BlockMetadata(size: currMd.size, expiry: max(currMd.expiry, minExpiry), refCount: currMd.refCount)
          res = StoreResult(kind: AlreadyInStore)

          # making sure that the block acutally is stored in the repoDs
          without hasBlock =? await self.repoDs.has(blkKey), err:
            raise err

          if not hasBlock:
            warn "Block metadata is present, but block is absent. Restoring block.", cid = blk.cid
            if err =? (await self.repoDs.put(blkKey, blk.data)).errorOption:
              raise err
        else:
          raise newException(CatchableError, "Repo already stores a block with the same cid but with a different size, cid: " & $blk.cid)
      else:
        md = BlockMetadata(size: blk.data.len.NBytes, expiry: minExpiry, refCount: 0)
        res = StoreResult(kind: Stored, used: blk.data.len.NBytes)
        if err =? (await self.repoDs.put(blkKey, blk.data)).errorOption:
          raise err

      (md.some, res)
  )

proc tryDeleteBlock(self: RepoStore, cid: Cid, expiryLimit = SecondsSince1970.low): Future[?!DeleteResult] {.async.} =
  if cid.isEmpty:
    return success(DeleteResult(kind: InUse))

  without metaKey =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)

  without blkKey =? makePrefixKey(self.postFixLen, cid), err:
    return failure(err)

  await self.metaDs.modifyTGetU(metaKey,
    proc (maybeCurrMd: ?BlockMetadata): Future[(?BlockMetadata, DeleteResult)] {.async.} =
      var
        maybeMeta: ?BlockMetadata
        res: DeleteResult

      if currMd =? maybeCurrMd:
        if currMd.refCount == 0 or currMd.expiry < expiryLimit:
          maybeMeta = BlockMetadata.none
          res = DeleteResult(kind: Deleted, released: currMd.size)

          if err =? (await self.repoDs.delete(blkKey)).errorOption:
            raise err
        else:
          maybeMeta = currMd.some
          res = DeleteResult(kind: InUse)
      else:
        maybeMeta = BlockMetadata.none
        res = DeleteResult(kind: NotFound)

        # making sure that the block acutally is removed from the repoDs
        without hasBlock =? await self.repoDs.has(blkKey), err:
          raise err

        if hasBlock:
          warn "Block metadata is absent, but block is present. Removing block.", cid
          if err =? (await self.repoDs.delete(blkKey)).errorOption:
            raise err

      (maybeMeta, res)
  )

###########################################################
# BlockStore API
###########################################################

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
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  without blk =? await self.getBlock(leafMd.blkCid), err:
    return failure(err)

  success((blk, leafMd.proof))

method getBlock*(self: RepoStore, treeCid: Cid, index: Natural): Future[?!Block] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  await self.getBlock(leafMd.blkCid)

method getBlock*(self: RepoStore, address: BlockAddress): Future[?!Block] =
  ## Get a block from the blockstore
  ##

  if address.leaf:
    self.getBlock(address.treeCid, address.index)
  else:
    self.getBlock(address.cid)

method ensureExpiry*(
    self: RepoStore,
    cid: Cid,
    expiry: SecondsSince1970
): Future[?!void] {.async.} =
  ## Ensure that block's associated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##

  if expiry <= 0:
    return failure(newException(ValueError, "Expiry timestamp must be larger then zero"))

  await self.updateBlockMetadata(cid, minExpiry = expiry)

method ensureExpiry*(
    self: RepoStore,
    treeCid: Cid,
    index: Natural,
    expiry: SecondsSince1970
): Future[?!void] {.async.} =
  ## Ensure that block's associated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##

  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  await self.ensureExpiry(leafMd.blkCid, expiry)

method putCidAndProof*(
  self: RepoStore,
  treeCid: Cid,
  index: Natural,
  blkCid: Cid,
  proof: CodexProof
): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  logScope:
    treeCid = treeCid
    index = index
    blkCid = blkCid

  trace "Storing LeafMetadata"

  without res =? await self.putLeafMetadata(treeCid, index, blkCid, proof), err:
    return failure(err)

  if blkCid.mcodec == BlockCodec:
    if res == Stored:
      if err =? (await self.updateBlockMetadata(blkCid, plusRefCount = 1)).errorOption:
        return failure(err)
      trace "Leaf metadata stored, block refCount incremented"
    else:
      trace "Leaf metadata already exists"

  return success()

method getCidAndProof*(
  self: RepoStore,
  treeCid: Cid,
  index: Natural
): Future[?!(Cid, CodexProof)] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  success((leafMd.blkCid, leafMd.proof))

method getCid*(
  self: RepoStore,
  treeCid: Cid,
  index: Natural
): Future[?!Cid] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  success(leafMd.blkCid)

method putBlock*(
  self: RepoStore,
  blk: Block,
  ttl = Duration.none): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  logScope:
    cid = blk.cid

  let expiry = self.clock.now() + (ttl |? self.blockTtl).seconds

  without res =? await self.storeBlock(blk, expiry), err:
    return failure(err)

  if res.kind == Stored:
    trace "Block Stored"
    if err =? (await self.updateQuotaUsage(plusUsed = res.used)).errorOption:
      # rollback changes
      without delRes =? await self.tryDeleteBlock(blk.cid), err:
        return failure(err)
      return failure(err)

    if err =? (await self.updateTotalBlocksCount(plusCount = 1)).errorOption:
      return failure(err)
  else:
    trace "Block already exists"

  return success()

method delBlock*(self: RepoStore, cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the blockstore when block refCount is 0 or block is expired
  ##

  logScope:
    cid = cid

  trace "Attempting to delete a block"

  without res =? await self.tryDeleteBlock(cid, self.clock.now()), err:
    return failure(err)

  if res.kind == Deleted:
    trace "Block deleted"
    if err =? (await self.updateTotalBlocksCount(minusCount = 1)).errorOption:
      return failure(err)

    if err =? (await self.updateQuotaUsage(minusUsed = res.released)).errorOption:
      return failure(err)
  elif res.kind == InUse:
    trace "Block in use, refCount > 0 and not expired"
  else:
    trace "Block not found in store"

  return success()

method delBlock*(self: RepoStore, treeCid: Cid, index: Natural): Future[?!void] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    if err of BlockNotFoundError:
      return success()
    else:
      return failure(err)

  if err =? (await self.updateBlockMetadata(leafMd.blkCid, minusRefCount = 1)).errorOption:
    if not (err of BlockNotFoundError):
      return failure(err)

  await self.delBlock(leafMd.blkCid) # safe delete, only if refCount == 0

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
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    if err of BlockNotFoundError:
      return success(false)
    else:
      return failure(err)

  await self.hasBlock(leafMd.blkCid)

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
  ## Get iterator with block expirations
  ##

  without query =? createBlockExpirationQuery(maxNumber, offset), err:
    trace "Unable to format block expirations query"
    return failure(err)

  without queryIter =? (await queryT[BlockMetadata](self.metaDs, query)), err:
    trace "Unable to execute block expirations query"
    return failure(err)

  let iter = queryIter.map(
    proc (fut: Future[(?Key, ?!BlockMetadata)]): Future[?BlockExpiration] {.async.} =
      let (maybeKey, blockMdOrErr) = await fut

      without key =? maybeKey:
        warn "Entry without a key"
        return BlockExpiration.none

      without cid =? Cid.init(key.value).mapFailure, err:
        error "Failed decoding cid", err = err.msg
        return BlockExpiration.none

      without blockMd =? blockMdOrErr, err:
        error "Failed fetching metadata for block", cid = cid, err = err.msg
        return BlockExpiration.none

      BlockExpiration(cid: cid, expiry: blockMd.expiry).some
  )

  iter.success

method close*(self: RepoStore): Future[void] {.async.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  trace "Closing repostore"

  if not self.metaDs.isNil:
    (await self.metaDs.close()).expect("Should meta datastore")

  if not self.repoDs.isNil:
    (await self.repoDs.close()).expect("Should repo datastore")

###########################################################
# RepoStore procs
###########################################################

proc reserve*(self: RepoStore, bytes: NBytes): Future[?!void] {.async.} =
  ## Reserve bytes
  ##

  trace "Reserving bytes", bytes

  await self.updateQuotaUsage(plusReserved = bytes)

proc release*(self: RepoStore, bytes: NBytes): Future[?!void] {.async.} =
  ## Release bytes
  ##

  trace "Releasing bytes", bytes

  await self.updateQuotaUsage(minusReserved = bytes)

proc start*(self: RepoStore): Future[void] {.async.} =
  ## Start repo
  ##

  if self.started:
    trace "Repo already started"
    return

  trace "Starting rep"
  if err =? (await self.updateTotalBlocksCount()).errorOption:
    raise newException(CodexError, err.msg)

  if err =? (await self.updateQuotaUsage()).errorOption:
    raise newException(CodexError, err.msg)

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
