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

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/lrucache
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ../chunker
import ../errors
import ../manifest

export blockstore

logScope:
  topics = "codex cachestore"

type
  CacheStore* = ref object of BlockStore
    backingStore: BlockStore
    cache: LruCache[Cid, Block]

const
  MiB* = 1024 * 1024
  DefaultCacheSizeMiB* = 5
  DefaultCacheSize* = DefaultCacheSizeMiB * MiB

method getBlock*(self: CacheStore, cid: Cid): Future[?!Block] {.async.} =
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success(cid.emptyBlock)

  if cid notin self.cache:
    without blk =? await self.backingStore.getBlock(cid), err:
      return failure(err)
    self.cache[blk.cid] = blk
    return success(blk)

  trace "Returning block from cache"
  return success self.cache[cid]

method hasBlock*(self: CacheStore, cid: Cid): Future[?!bool] =
  self.backingStore.hasBlock(cid)

method listBlocks*(
  self: CacheStore,
  blockType = BlockType.Manifest): Future[?!BlocksIter] =
  self.backingStore.listBlocks(blockType)

method putBlock*(
  self: CacheStore,
  blk: Block,
  ttl = Duration.none): Future[?!void] =
  self.backingStore.putBlock(blk, ttl)

method delBlock*(self: CacheStore, cid: Cid): Future[?!void] =
  discard self.cache.del(cid)
  self.backingStore.delBlock(cid)

method close*(self: CacheStore): Future[void] =
  self.backingStore.close()

func new*(
    _: type CacheStore,
    backingStore: BlockStore,
    cacheSize: Positive = DefaultCacheSize,
    chunkSize: Positive = DefaultChunkSize
  ): CacheStore {.raises: [Defect, ValueError].} =

  if cacheSize < chunkSize:
    raise newException(ValueError, "cacheSize cannot be less than chunkSize")

  let
    size = cacheSize div chunkSize
    cache = newLruCache[Cid, Block](size)
    store = CacheStore(
      backingStore: backingStore,
      cache: cache)

  return store
