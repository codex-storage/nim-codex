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

export blockstore, blockexchange, asyncheapqueue

logScope:
  topics = "codex networkstore"

type
  NetworkStore* = ref object of BlockStore
    engine*: BlockExcEngine # blockexc decision engine
    localStore*: BlockStore # local block store

method getBlock*(self: NetworkStore, cid: Cid): Future[?!bt.Block] {.async.} =
  ## Get a block from a remote peer
  ##

  trace "Getting block from local store or network", cid

  if not (await cid in self.localStore):
    trace "Block not in local store", cid

    try:
      # TODO: What if block isn't available in the engine too?
      let
        blk = await self.engine.requestBlock(cid)

      # TODO: add block to the local store
      return success blk
    except CatchableError as exc:
      trace "Error requesting block from network", cid, error = exc.msg
      return failure exc

  return await self.localStore.getBlock(cid)

method putBlock*(self: NetworkStore, blk: bt.Block): Future[?!void] {.async.} =
  ## Store block locally and notify the network
  ##

  trace "Puting block into network store", cid = blk.cid

  let res = await self.localStore.putBlock(blk)
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

  if not self.localStore.isNil: await self.localStore.close

proc new*(
  T: type NetworkStore,
  engine: BlockExcEngine,
  localStore: BlockStore): T =

  let b = NetworkStore(
    localStore: localStore,
    engine: engine)

  return b
