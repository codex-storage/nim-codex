## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.


{.push raises: [].}

import pkg/chronos
import pkg/libp2p
import pkg/questionable/results

import ../clock
import ../blocktype
import ../blockexchange
import ../logutils
import ../merkletree
import ../utils/asyncheapqueue
import ../utils/asynciter
import ./blockstore

export blockstore, blockexchange, asyncheapqueue

logScope:
  topics = "codex networkstore"

type
  NetworkStore* = ref object of BlockStore
    engine*: BlockExcEngine # blockexc decision engine
    localStore*: BlockStore # local block store

method getBlock*(self: NetworkStore, address: BlockAddress): Future[?!Block] {.async.} =
  without blk =? (await self.localStore.getBlock(address)), err:
    if not (err of BlockNotFoundError):
      error "Error getting block from local store", address, err = err.msg
      return failure err

    without newBlock =? (await self.engine.requestBlock(address)), err:
      error "Unable to get block from exchange engine", address, err = err.msg
      return failure err

    return success newBlock

  return success blk

method getBlock*(self: NetworkStore, cid: Cid): Future[?!Block] =
  ## Get a block from the blockstore
  ##

  self.getBlock(BlockAddress.init(cid))

method getBlock*(self: NetworkStore, treeCid: Cid, index: Natural): Future[?!Block] =
  ## Get a block from the blockstore
  ##

  self.getBlock(BlockAddress.init(treeCid, index))

method putBlock*(
  self: NetworkStore,
  blk: Block): Future[?!void] {.async.} =
  ## Store block locally and notify the network
  ##

  trace "Putting block into network store", cid = blk.cid

  let res = await self.localStore.putBlock(blk)
  if res.isErr:
    return res

  await self.engine.resolveBlocks(@[blk])
  return success()

method putCidAndProof*(
  self: NetworkStore,
  treeCid: Cid,
  index: Natural,
  blockCid: Cid,
  proof: CodexProof): Future[?!void] =
  self.localStore.putCidAndProof(treeCid, index, blockCid, proof)

method getCidAndProof*(
  self: NetworkStore,
  treeCid: Cid,
  index: Natural): Future[?!(Cid, CodexProof)] =
  ## Get a block proof from the blockstore
  ##

  self.localStore.getCidAndProof(treeCid, index)

method listBlocks*(
  self: NetworkStore,
  blockType = BlockType.Manifest): Future[?!AsyncIter[?Cid]] =
  self.localStore.listBlocks(blockType)

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
  NetworkStore(localStore: localStore, engine: engine)
