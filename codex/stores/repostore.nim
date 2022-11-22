## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os

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
import ../blocktype
import ../namespaces
import ../manifest

export blocktype, libp2p

logScope:
  topics = "codex repostore"

const
  QuotaKey* = Key.init(CodexMetaNamespace / "cache").tryGet
  CacheBytesKey* = Key.init(CacheQuotaNamespace / "cache").tryGet
  PersistBytesKey* = Key.init(CacheQuotaNamespace / "persist").tryGet

  CodexMetaKey* = Key.init(CodexMetaNamespace).tryGet
  CodexRepoKey* = Key.init(CodexRepoNamespace).tryGet
  CodexBlocksKey* = Key.init(CodexBlocksNamespace).tryGet
  CodexManifestKey* = Key.init(CodexManifestNamespace).tryGet

  DefaultCacheTtl* = 24.hours
  DefaultCacheBytes* = 1'u shl 33'u # ~8GB
  DefaultPersistBytes* = 1'u shl 33'u # ~8GB

type
  CacheQuotaUsedError* = object of CodexError
  PersistQuotaUsedError* = object of CodexError

  RepoStore* = ref object of BlockStore
    postFixLen*: int
    repoDs*: Datastore
    metaDs*: Datastore
    cacheBytes*: uint
    currentCacheBytes*: uint
    persistBytes*: uint
    currentPersistBytes*: uint
    started*: bool

func makePrefixKey*(self: RepoStore, cid: Cid): ?!Key =
  let
    cidKey = ? Key.init(($cid)[^self.postFixLen..^1] / $cid)

  if ? cid.isManifest:
    success CodexManifestKey / cidKey
  else:
    success CodexBlocksKey / cidKey

method getBlock*(self: RepoStore, cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the blockstore
  ##

  without key =? self.makePrefixKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  without data =? await self.repoDs.get(key), err:
    if not (err of DatastoreKeyNotFound):
      trace "Error getting block from datastore", err = err.msg, key
      return failure(err)

    return failure(newException(BlockNotFoundError, err.msg))

  trace "Got block for cid", cid
  return Block.new(cid, data)

method putBlock*(
  self: RepoStore,
  blk: Block,
  persist = false): Future[?!void] {.async, base.} =
  ## Put a block to the blockstore
  ##

  if await blk.cid in self:
    trace "Block already in repo, skipping", cid = blk.cid
    return success()

  if persist and (self.currentPersistBytes + blk.data.len.uint) > self.persistBytes:
    error "Cannot persist block, quota used!",
      persistBytes = self.persistBytes, used = self.persistBytes + blk.data.len.uint

    return failure(
      newException(PersistQuotaUsedError, "Cannot persist block, quota used!"))
  elif (self.currentCacheBytes + blk.data.len.uint) > self.cacheBytes:
    error "Cannot cache block, quota used!",
      cacheBytes = self.cacheBytes, used = (self.cacheBytes + blk.data.len.uint)

    return failure(
      newException(CacheQuotaUsedError, "Cannot cache block, quota used!"))

  without key =? self.makePrefixKey(blk.cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  trace "Storing block with key", key

  if err =? (await self.repoDs.put(key, blk.data)).errorOption:
    trace "Error storing block", err = err.msg
    return failure(err)

  let (quotaKey, bytes) =
    if persist:
      self.currentPersistBytes += blk.data.len.uint
      (PersistBytesKey, @(self.currentPersistBytes.uint64.toBytesBE))
    else:
      self.currentCacheBytes += blk.data.len.uint
      (CacheBytesKey, @(self.currentCacheBytes.uint64.toBytesBE))

  if err =? (await self.metaDs.put(quotaKey, bytes)).errorOption:
    trace "Error updating quota bytes", err = err.msg, persist

    if err =? (await self.repoDs.delete(key)).errorOption:
      trace "Error direleting block after failed quota update", err = err.msg
      return failure(err)

    return failure(err)

  return success()

method putBlock*(self: RepoStore, blk: Block): Future[?!void] =
  ## Put a block to the blockstore
  ##

  return self.putBlock(blk, persist = false)

method delBlock*(self: RepoStore, cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the blockstore
  ##

  without key =? self.makePrefixKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  return await self.repoDs.delete(key)

method hasBlock*(self: RepoStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  without key =? self.makePrefixKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  return await self.repoDs.contains(key)

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

method close*(self: RepoStore): Future[void] {.async.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  (await self.repoDs.close()).expect("Should close datastore")

proc hasBlock*(self: RepoStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore.
  ## Return false if error encountered
  ##

  without key =? self.makePrefixKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err.msg)

  return await self.repoDs.contains(key)

method persistBlock*(self: BlockStore, cid: Cid, persist = true): Future[?!Block] {.base.} =
  ## Mark/un-mark block as persisted
  ##

  raiseAssert("Not implemented!")

method isPersisted*(self: BlockStore, cid: Cid): Future[bool] =
  ## Check if blocks is persisted
  ##

  raiseAssert("Not implemented!")

proc start*(self: RepoStore): Future[void] {.async.} =
  ## Start repo
  ##

  if self.started:
    trace "Repo already started"
    return

  trace "Starting repo"

  ## load current persist and cache bytes from meta ds
  without cacheBytes =? await self.metaDs.get(CacheBytesKey), err:
    if not (err of DatastoreKeyNotFound):
      error "Error getting cache bytes from datastore", err = err.msg, key = $CacheBytesKey
      raise newException(Defect, err.msg)

  if cacheBytes.len > 0:
    self.currentCacheBytes = uint64.fromBytesBE(cacheBytes).uint

  notice "Current bytes used for cache quota", bytes = self.currentCacheBytes

  without persistBytes =? await self.metaDs.get(PersistBytesKey), err:
    if not (err of DatastoreKeyNotFound):
      error "Error getting persist bytes from datastore", err = err.msg, key = $PersistBytesKey
      raise newException(Defect, err.msg)

  if persistBytes.len > 0:
    self.currentPersistBytes = uint64.fromBytesBE(persistBytes).uint

  notice "Current bytes used for persist quota", bytes = self.currentPersistBytes

  self.started = true

proc stop*(self: RepoStore): Future[void] {.async.} =
  ## Stop repo
  ##

  if self.started:
    trace "Repo is not started"
    return

  trace "Stopping repo"

func new*(
  T: type RepoStore,
  repoDs: Datastore,
  metaDs: Datastore,
  postFixLen = 2,
  cacheBytes = DefaultCacheBytes,
  persistBytes = DefaultPersistBytes): T =

  T(
    repoDs: repoDs,
    metaDs: metaDs,
    postFixLen: postFixLen,
    cacheBytes: cacheBytes,
    persistBytes: persistBytes)
