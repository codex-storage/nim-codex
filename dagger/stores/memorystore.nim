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

import pkg/chronos
import pkg/libp2p
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ../blocktype

export blockstore

logScope:
  topics = "dagger memstore"

type
  MemoryStore* = ref object of BlockStore
    blocks: seq[Block] # TODO: Should be an LRU cache

method getBlock*(
  b: MemoryStore,
  cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the stores
  ##

  trace "Getting block", cid
  let found = b.blocks.filterIt(
    it.cid == cid
  )

  if found.len <= 0:
    return failure("Couldn't get block")

  trace "Retrieved block", cid

  return found[0].success

method hasBlock*(s: MemoryStore, cid: Cid): bool =
  ## check if the block exists
  ##

  s.blocks.anyIt( it.cid == cid )

method putBlock*(
  s: MemoryStore,
  blk: Block): Future[bool] {.async.} =
  ## Put a block to the blockstore
  ##

  trace "Putting block", cid = blk.cid
  s.blocks.add(blk)

  return blk.cid in s

method delBlock*(
  s: MemoryStore,
  cid: Cid): Future[bool] {.async.} =
  ## delete a block/s from the block store
  ##

  s.blocks.keepItIf( it.cid != cid )
  return cid notin s

func new*(_: type MemoryStore, blocks: openArray[Block] = []): MemoryStore =
  MemoryStore(
    blocks: @blocks
  )
