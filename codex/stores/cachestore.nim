## Nim-Codex
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

import std/times
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
    currentSize*: Natural          # in bytes
    size*: Positive                # in bytes
    cache: LruCache[Cid, Block]

  InvalidBlockSize* = object of CodexError

const
  MiB* = 1024 * 1024 # bytes, 1 mebibyte = 1,048,576 bytes
  DefaultCacheSizeMiB* = 5
  DefaultCacheSize* = DefaultCacheSizeMiB * MiB # bytes

method getBlock*(self: CacheStore, cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the stores
  ##

  trace "Getting block from cache", cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success cid.emptyBlock

  if cid notin self.cache:
    return failure (ref BlockNotFoundError)(msg: "Block not in cache")

  try:
    return success self.cache[cid]
  except CatchableError as exc:
    trace "Error requesting block from cache", cid, error = exc.msg
    return failure exc

method hasBlock*(self: CacheStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking CacheStore for block presence", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true.success

  return (cid in self.cache).success

func cids(self: CacheStore): (iterator: Cid {.gcsafe.}) =
  return iterator(): Cid =
    for cid in self.cache.keys:
      yield cid

method listBlocks*(
  self: CacheStore,
  blockType = BlockType.Manifest): Future[?!BlocksIter] {.async.} =
  ## Get the list of blocks in the BlockStore. This is an intensive operation
  ##

  var
    iter = BlocksIter()

  let
    cids = self.cids()

  proc next(): Future[?Cid] {.async.} =
    await idleAsync()

    var cid: Cid
    while true:
      if iter.finished:
        return Cid.none

      cid = cids()

      if finished(cids):
        iter.finished = true
        return Cid.none

      without isManifest =? cid.isManifest, err:
        trace "Error checking if cid is a manifest", err = err.msg
        return Cid.none

      case blockType:
      of BlockType.Manifest:
        if not isManifest:
          trace "Cid is not manifest, skipping", cid
          continue

        break
      of BlockType.Block:
        if isManifest:
          trace "Cid is a manifest, skipping", cid
          continue

        break
      of BlockType.Both:
        break

    return cid.some

  iter.next = next

  return success iter

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
  blk: Block,
  ttl = times.Duration.none): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  trace "Storing block in cache", cid = blk.cid
  if blk.isEmpty:
    trace "Empty block, ignoring"
    return success()

  discard self.putBlockSync(blk)
  return success()

method delBlock*(self: CacheStore, cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block from cache", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success()

  let removed = self.cache.del(cid)
  if removed.isSome:
    self.currentSize -= removed.get.data.len

  return success()

method close*(self: CacheStore): Future[void] {.async.} =
  ## Close the blockstore, a no-op for this implementation
  ##

  discard

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
