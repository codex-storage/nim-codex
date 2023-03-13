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
import std/tables

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ../chunker
import ../errors
import ../manifest

export blockstore

logScope:
  topics = "codex memorystore"

type
  MemoryStore* = ref object of BlockStore
    bytesUsed*: int
    capacity*: int
    table: Table[Cid, Block]

const
  MiB* = 1024 * 1024
  DefaultMemoryStoreCapacityMiB* = 5
  DefaultMemoryStoreCapacity* = DefaultMemoryStoreCapacityMiB * MiB

method getBlock*(self: MemoryStore, cid: Cid): Future[?!Block] {.async.} =
  trace "Getting block from cache", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success cid.emptyBlock

  if cid notin self.table:
    return failure (ref BlockNotFoundError)(msg: "Block not in memory store")

  try:
    return success self.table[cid]
  except CatchableError as exc:
    trace "Error getting block from memory store", cid, error = exc.msg
    return failure exc

method hasBlock*(self: MemoryStore, cid: Cid): Future[?!bool] {.async.} =
  trace "Checking MemoryStore for block presence", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true.success

  return (cid in self.table).success

func cids(self: MemoryStore): (iterator: Cid {.gcsafe.}) =
  return iterator(): Cid =
    for cid in self.table.keys:
      yield cid

method listBlocks*(self: MemoryStore, blockType = BlockType.Manifest): Future[?!BlocksIter] {.async.} =
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

proc getFreeCapacity(self: MemoryStore): int =
  self.capacity - self.bytesUsed

func putBlockSync(self: MemoryStore, blk: Block): ?!void =
  let
    freeCapacity = self.getFreeCapacity()
    blkSize = blk.data.len

  if blkSize > freeCapacity:
    trace "Block size is larger than free capacity", blk = blkSize, freeCapacity
    return failure("Unable to store block: Insufficient free capacity.")

  self.table[blk.cid] = blk
  self.bytesUsed += blkSize
  return success()

method putBlock*(self: MemoryStore, blk: Block, ttl = Duration.none): Future[?!void] {.async.} =
  trace "Storing block in store", cid = blk.cid
  if blk.isEmpty:
    trace "Empty block, ignoring"
    return success()

  return self.putBlockSync(blk)

method delBlock*(self: MemoryStore, cid: Cid): Future[?!void] {.async.} =
  trace "Deleting block from memory store", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success()

  without toRemove =? await self.getBlock(cid), err:
    trace "Unable to find block to remove"
    return failure(err)

  self.table.del(cid)
  self.bytesUsed -= toRemove.data.len

  return success()

method close*(self: MemoryStore): Future[void] {.async.} =
  discard

func new*(
    _: type MemoryStore,
    blocks: openArray[Block] = [],
    capacity: Positive = DefaultMemoryStoreCapacity,
  ): MemoryStore {.raises: [Defect, ValueError].} =

  let store = MemoryStore(
      table: initTable[Cid, Block](),
      bytesUsed: 0,
      capacity: capacity)

  for blk in blocks:
    discard store.putBlockSync(blk)

  return store
