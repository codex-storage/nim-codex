## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import std/options

import pkg/chronos
import pkg/chronicles
import pkg/datastore/sqlite_datastore
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ./cachestore

export blockstore, sqlite_datastore

logScope:
  topics = "codex sqlitestore"

type
  SQLiteStore* = ref object of BlockStore
    cache: BlockStore
    datastore: SQLiteDatastore

const
  allBlocks = when (let keyRes = Key.init("*"); true):
    if keyRes.isOk: Query.init(keyRes.get)
    else: raise (ref Defect)(msg: keyRes.error.msg)

proc new*(
  T: type SQLiteStore,
  repoDir: string,
  cache: BlockStore = CacheStore.new()): T =

  let
    datastoreRes = SQLiteDatastore.new(repoDir)

  if datastoreRes.isErr:
    raise (ref Defect)(msg: datastoreRes.error.msg)

  T(cache: cache, datastore: datastoreRes.get)

proc datastore*(self: SQLiteStore): SQLiteDatastore =
  self.datastore

proc blockKey*(blockCid: Cid): ?!Key =
  let
    keyRes = Key.init($blockCid)

  if keyRes.isErr:
    trace "Unable to construct CID from key", cid = blockCid, error = keyRes.error.msg

  keyRes

method getBlock*(
  self: SQLiteStore,
  cid: Cid): Future[?!(?Block)] {.async.} =
  ## Get a block from the cache or database.
  ## Save a copy to the cache if present in the database but not in the cache
  ##

  trace "Getting block from cache or database", cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success cid.emptyBlock.some

  without cachedBlkOpt =? await self.cache.getBlock(cid), error:
    trace "Unable to read block from cache", cid, error = error.msg

  if cachedBlkOpt.isSome:
    return success cachedBlkOpt

  without blkKey =? blockKey(cid), error:
    return failure error

  without dataOpt =? await self.datastore.get(blkKey), error:
    trace "Unable to read block from database", key = blkKey.id, error = error.msg
    return failure error

  without data =? dataOpt:
    return success Block.none

  without blk =? Block.new(cid, data), error:
    trace "Unable to construct block from data", cid, error = error.msg
    return failure error

  let
    putCachedRes = await self.cache.putBlock(blk)

  if putCachedRes.isErr:
    trace "Unable to store block in cache", cid, error = putCachedRes.error.msg

  return success blk.some

method putBlock*(
  self: SQLiteStore,
  blk: Block): Future[?!void] {.async.} =
  ## Write a block's contents to the database with key based on blk.cid.
  ## Save a copy to the cache
  ##

  trace "Putting block into database and cache", cid = blk.cid

  if blk.isEmpty:
    trace "Empty block, ignoring"
    return success()

  without blkKey =? blockKey(blk.cid), error:
    return failure error

  let
    putRes = await self.datastore.put(blkKey, blk.data)

  if putRes.isErr:
    trace "Unable to store block in database", key = blkKey.id, error = putRes.error.msg
    return failure putRes.error

  let
    putCachedRes = await self.cache.putBlock(blk)

  if putCachedRes.isErr:
    trace "Unable to store block in cache", cid = blk.cid, error = putCachedRes.error.msg

  return success()

method delBlock*(
  self: SQLiteStore,
  cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the database and cache
  ##

  trace "Deleting block from cache and database", cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success()

  let
    delCachedRes = await self.cache.delBlock(cid)

  if delCachedRes.isErr:
    trace "Unable to delete block from cache", cid, error = delCachedRes.error.msg

  without blkKey =? blockKey(cid), error:
    return failure error

  let
    delRes = await self.datastore.delete(blkKey)

  if delRes.isErr:
    trace "Unable to delete block from database", key = blkKey.id, error = delRes.error.msg
    return failure delRes.error

  return success()

method hasBlock*(
  self: SQLiteStore,
  cid: Cid): Future[?!bool] {.async.} =
  ## Check if a block exists in the database
  ##

  trace "Checking database for block existence", cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true.success

  without blkKey =? blockKey(cid), error:
    return failure error

  return await self.datastore.contains(blkKey)

method listBlocks*(
  self: SQLiteStore,
  onBlock: OnBlock): Future[?!void] {.async.} =
  ## Process list of all blocks in the database via callback.
  ## This is an intensive operation
  ##

  for kd in self.datastore.query(allBlocks):
    let
      (key, _) = await kd
      cidRes = Cid.init(key.name)

    if cidRes.isOk:
      await onBlock(cidRes.get)
    else:
      trace "Unable to construct CID from key", key = key.id, error = $cidRes.error

  return success()

method close*(self: SQLiteStore): Future[void] {.async.} =
  ## Close the underlying cache and SQLite datastore
  ##

  if not self.cache.isNil: await self.cache.close
  if not self.datastore.isNil: self.datastore.close
