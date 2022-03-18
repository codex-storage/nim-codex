## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/options

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/lrucache
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ../blocktype
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

  return self.cache[cid].catch()

method hasBlock*(self: CacheStore, cid: Cid): bool =
  ## check if the block exists
  ##

  self.cache.contains(cid)

func putBlockSync(self: CacheStore, blk: Block): bool =

  let blkSize = blk.data.len # in bytes

  if blkSize > self.size:
    return false

  while self.currentSize + blkSize > self.size:
    try:
      let removed = self.cache.removeLru()
      self.currentSize -= removed.data.len
    except EmptyLruCacheError:
      # if the cache is empty, can't remove anything, so break and add item
      # to the cache
      break

  self.cache[blk.cid] = blk
  self.currentSize += blkSize
  return true

method putBlock*(
  self: CacheStore,
  blk: Block): Future[bool] {.async.} =
  ## Put a block to the blockstore
  ##
  return self.putBlockSync(blk)

method delBlock*(
  self: CacheStore,
  cid: Cid): Future[bool] {.async.} =
  ## delete a block/s from the block store
  ##

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
