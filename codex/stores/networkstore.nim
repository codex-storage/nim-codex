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

import pkg/chronicles
import pkg/chronos
import pkg/libp2p

import ../blocktype as bt
import ../utils/asyncheapqueue

import ./blockstore
import ../blockexchange
import ../merkletree

export blockstore, blockexchange, asyncheapqueue

logScope:
  topics = "codex networkstore"

type
  NetworkStore* = ref object of BlockStore
    engine*: BlockExcEngine # blockexc decision engine
    localStore*: BlockStore # local block store

method getBlock*(self: NetworkStore, cid: Cid): Future[?!bt.Block] {.async.} =
  trace "Getting block from local store or network", cid

  without blk =? await self.localStore.getBlock(cid), error:
    if not (error of BlockNotFoundError): return failure error
    trace "Block not in local store", cid

    without newBlock =? (await self.engine.requestBlock(cid)).catch, error:
      trace "Unable to get block from exchange engine", cid
      return failure error

    return success newBlock

  return success blk

method getBlock*(self: NetworkStore, treeCid: Cid, index: Natural): Future[?!bt.Block] {.async.} =
  return await self.localStore.getBlock(treeCid, index)

method getBlockAndProof*(self: NetworkStore, treeCid: Cid, index: Natural): Future[?!(bt.Block, MerkleProof)] {.async.} =
  return await self.localStore.getBlockAndProof(treeCid, index)

method getBlocks*(self: NetworkStore, treeCid: Cid, leavesCount: Natural, merkleRoot: MultiHash): Future[?!BlockIter] {.async.} =
  without blocksIter =? await self.localStore.getBlocks(treeCid, leavesCount, merkleRoot), err:
    if err of BlockNotFoundError:
      trace "Tree not in local store", treeCid
      without wrappedIter =? self.engine.requestBlocks(treeCid, leavesCount, merkleRoot), err:
        failure(err)

      var iter = BlockIter()

      proc next(): Future[?!Block] {.async.} =
        if not wrappedIter.finished:
          # TODO try-catch
          let blk = await wrappedIter.next()
          iter.finished = wrappedIter.finished
          return success(blk)
        else:
          return failure("No more elements for tree with cid " & $treeCid)
      
      return success(iter)

    else: 
      return failure(err)


method putBlock*(
    self: NetworkStore,
    blk: bt.Block,
    ttl = Duration.none
): Future[?!void] {.async.} =
  ## Store block locally and notify the network
  ##

  trace "Puting block into network store", cid = blk.cid

  let res = await self.localStore.putBlock(blk, ttl)
  if res.isErr:
    return res

  await self.engine.resolveBlocks(@[blk])
  return success()

method delBlock*(self: NetworkStore, cid: Cid): Future[?!void] =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block from network store", cid
  return self.localStore.delBlock(cid)

{.pop.}

method hasBlock*(self: NetworkStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking network store for block existence", cid
  return await self.localStore.hasBlock(cid)

method close*(self: NetworkStore): Future[void] {.async.} =
  ## Close the underlying local blockstore
  ##

  if not self.localStore.isNil:
    await self.localStore.close

proc new*(
  T: type NetworkStore,
  engine: BlockExcEngine,
  localStore: BlockStore
): NetworkStore =
  ## Create new instance of a NetworkStore 
  ## 
  NetworkStore(
      localStore: localStore,
      engine: engine)
