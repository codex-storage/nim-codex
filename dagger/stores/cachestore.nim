## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/sequtils

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/lrucache
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ../blocktype
import ../chunker

export blockstore

logScope:
  topics = "dagger cachestore"

type
  CacheStore* = ref object of BlockStore
    size: Positive                # in number of blocks
    cache: LruCache[Cid, Block]

const
  MiB* = 1024 * 1024 # bytes, 1 mebibyte = 1,048,576 bytes
  DefaultCacheSizeMiB* = 100
  DefaultCacheSize* = DefaultCacheSizeMiB * MiB

method getBlock*(
  b: CacheStore,
  cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the stores
  ##

  return b.cache[cid].catch()

method hasBlock*(s: CacheStore, cid: Cid): bool =
  ## check if the block exists
  ##

  s.cache.contains(cid)

method putBlock*(
  s: CacheStore,
  blk: Block): Future[bool] {.async.} =
  ## Put a block to the blockstore
  ##

  s.cache[blk.cid] = blk
  return true

method delBlock*(
  s: CacheStore,
  cid: Cid): Future[bool] {.async.} =
  ## delete a block/s from the block store
  ##

  s.cache.del(cid)
  return true

func new*(
    _: type CacheStore,
    blocks: openArray[Block] = [],
    cacheSize: Positive = DefaultCacheSize, # in bytes
    chunkSize: Positive = DefaultChunkSize  # in bytes
  ): CacheStore {.raises: [Defect, ValueError].} =

  if cacheSize < chunkSize:
    raise newException(ValueError, "cacheSize cannot be less than chunkSize")

  let
    size = cacheSize div chunkSize
    blks =
      if blocks.len > size:
        let start = blocks.len - size
        blocks[start..^1]
      else: @blocks
    cache = newLruCache[Cid, Block](size)

  for blk in blks:
    cache[blk.cid] = blk

  CacheStore(
    cache: cache,
    size: size
  )
