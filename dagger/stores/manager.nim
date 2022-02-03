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
import std/sugar

import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ./blockstore

logScope:
  topics = "dagger blockstoremanager"

type
  BlockStoreManager* = ref object
    stores: seq[BlockStore]

method getBlock*(
  self: BlockStoreManager,
  cid: Cid): Future[?!Block] {.async.} =
  ## Cycle through stores, in order of insertion, to get a block.
  ## Cycling short circuits once a block is found.
  ## In practice, this should query from most local to most remote, eg:
  ## MemoryStore > FSStore
  ##

  for store in self.stores:
    logScope:
      cid
      store = $(typeof store)
    trace "Getting block"
    let blk = await store.getBlock(cid)
    if blk.isOk:
      trace "Retrieved block from store"
      return blk
    else:
      trace "Couldn't get from store"

  return Block.failure("Couldn't find block in any stores")

method getBlocks*(
  self: BlockStoreManager,
  cids: seq[Cid]): Future[seq[Block]] {.async.} =
  ## Gets blocks from each local store in the BlockStoreManager.
  ## Cycle through local stores, in order of insertion, to get a block.
  ## In practice, this should query from most local to least local, eg:
  ## MemoryStore > FSStore
  ## Each block request stops cycling BlockStores once a block is found.
  ##

  let getFuts = await allFinished(cids.map(cid => self.getBlock(cid)))
  return getFuts
          .filterIt((not it.failed) and it.read.isOk)
          .mapIt(!it.read) # extract Block value

method putBlock*(
  self: BlockStoreManager,
  blk: Block): Future[bool] {.async.} =
  ## Put a block to each local store in the BlockStoreManager.
  ## Cycle through local stores, in order of insertion, to put a block.
  ## In practice, this should query from most local to least local, eg:
  ## MemoryStore > FSStore
  ##

  var success = true
  for store in self.stores:
    logScope:
      cid = blk.cid
      store = $(typeof store)
    trace "Putting block in store"
    # TODO: Could we use asyncSpawn here as we likely don't need to check
    # if putBlock failed or not (think in terms of a network-based storage
    # where an operation may take a long time)?
    var storeSuccess = await store.putBlock(blk)
    if not storeSuccess:
      trace "Couldn't put block in store"

      # allow the operation to fail without affecting the return value
      # (ie which indicatees if the put operation was successful or not)
      if store.canFail:
        storeSuccess = true

      if not store.onPutFail.isNil:
        asyncSpawn store.onPutFail(store, blk)

    else: trace "Put block in store"
    success = success and storeSuccess

  return success

method putBlocks*(
  self: BlockStoreManager,
  blks: seq[Block]): Future[bool] {.async.} =
  ## Put blocks to each local store in the BlockStoreManager.
  ## Cycle through local stores, in order of insertion, to put a block.
  ## In practice, this should query from most local to least local, eg:
  ## MemoryStore > FSStore
  ##

  let
    putFuts = await allFinished(blks.map(blk => self.putBlock(blk)))
    success = putFuts.allIt(not it.failed and it.read) # extract bool value

  return success

method delBlock*(
  self: BlockStoreManager,
  cid: Cid): Future[bool] {.async.} =
  ## Delete a block from each local block store in the BlockStoreManager.
  ## Cycle through local stores, in order of insertion, to delete a block.
  ## In practice, this should query from most local to least local, eg:
  ## MemoryStore > FSStore
  ##

  var success = true
  for store in self.stores:
    logScope:
      cid
      store = $(typeof store)
    trace "Deleting block from store"
    # TODO: Could we use asyncSpawn here as we likely don't need to check
    # if deletion failed or not?
    var storeSuccess = await store.delBlock(cid)
    if not storeSuccess:
      trace "Couldn't delete from store"

      # allow the operation to fail without affecting the return value
      # (ie which indicatees if the put operation was successful or not)
      if store.canFail:
        storeSuccess = true

      if not store.onDelFail.isNil:
        asyncSpawn store.onDelFail(store, cid)

    else: trace "Deleted block from store"
    success = success and storeSuccess

  return success

method hasBlock*(self: BlockStoreManager, cid: Cid): bool =
  ## Check if the block exists in the BlockStoreManager
  ##

  for store in self.stores:
    logScope:
      cid
      store = $(typeof store)

    trace "Checking has block"
    if store.hasBlock(cid):
      trace "Store has block"
      return true
    else:
      trace "Store doesn't have block"

method contains*(self: BlockStoreManager, blk: Cid): bool =
  self.hasBlock(blk)

proc new*(
  T: type BlockStoreManager,
  stores: seq[BlockStore]): T =

  let b = BlockStoreManager(
    stores: stores)

  return b