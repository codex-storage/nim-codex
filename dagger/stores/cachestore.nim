## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
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

export blockstore

logScope:
  topics = "dagger cachestore"

type
  CacheStore* = ref object of BlockStore
    currentSize*: Natural          # in bytes
    size*: Positive                # in bytes
    cache: LruCache[Cid, Block]

  InvalidBlockSize* = object of DaggerError

const
  MiB* = 1024 * 1024 # bytes, 1 mebibyte = 1,048,576 bytes
  DefaultCacheSizeMiB* = 100
  DefaultCacheSize* = DefaultCacheSizeMiB * MiB # bytes

method getBlock*(
  self: CacheStore,
  cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the stores
  ##

  trace "Getting block from cache", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return cid.emptyBlock.success

  return self.cache[cid].catch()

method hasBlock*(self: CacheStore, cid: Cid): bool =
  ## check if the block exists
  ##

  trace "Checking for block presence in cache", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true

  cid in self.cache

method listBlocks*(s: CacheStore, onBlock: OnBlock) {.async.} =
  for cid in toSeq(s.cache.keys):
    without blk =? (await s.getBlock(cid)):
      trace "Couldn't get block", cid = $cid

    await onBlock(blk)

func putBlockSync(self: CacheStore, blk: Block): bool =

  let blkSize = blk.data.len # in bytes

  if blkSize > self.size:
    trace "Block size is larger than cache size", blk = blkSize, cache = self.size
    return false

  while self.currentSize + blkSize > self.size:
    try:
      let removed = self.cache.removeLru()
      self.currentSize -= removed.data.len
    except EmptyLruCacheError as exc:
      # if the cache is empty, can't remove anything, so break and add item
      # to the cache
      trace "Exception puting block to cache", exc = exc.msg
      break

  self.cache[blk.cid] = blk
  self.currentSize += blkSize
  return true

method putBlock*(
  self: CacheStore,
  blk: Block): Future[bool] {.async.} =
  ## Put a block to the blockstore
  ##

  trace "Storing block in cache", cid = blk.cid
  if blk.isEmpty:
    trace "Empty block, ignoring"
    return true

  return self.putBlockSync(blk)

method delBlock*(
  self: CacheStore,
  cid: Cid): Future[bool] {.async.} =
  ## delete a block/s from the block store
  ##

  trace "Deleting block from cache", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true

  try:
    let removed = self.cache.del(cid)
    if removed.isSome:
      self.currentSize -= removed.get.data.len
      return true
    return false
  except EmptyLruCacheError:
    return false

func new*(
    _: type CacheStore,
    blocks: openArray[Block] = [],
    cacheSize: Positive = DefaultCacheSize, # in bytes
    chunkSize: Positive = DefaultChunkSize  # in bytes
  ): CacheStore {.raises: [Defect, ValueError].} =

  if cacheSize < chunkSize:
    raise newException(ValueError, "cacheSize cannot be less than chunkSize")

  var currentSize = 0
  let
    size = cacheSize div chunkSize
    cache = newLruCache[Cid, Block](size)
    store = CacheStore(
      cache: cache,
      currentSize: currentSize,
      size: cacheSize)

  for blk in blocks:
    discard store.putBlockSync(blk)

  return store
