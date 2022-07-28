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

method getBlock*(self: NetworkStore, cid: Cid): Future[?! (? bt.Block)] {.async.} =
  ## Get a block from a remote peer
  ##

  trace "Getting block from network store", cid

  let blk = await self.localStore.getBlock(cid)
  if blk.isErr:
    return blk
  if blk.get.isSome:
    trace "Retrieved block from local store", cid
    return blk

  trace "Block not found in local store", cid
  try:
    # TODO: What if block isn't available in the engine too?
    let blk = await self.engine.requestBlock(cid)
    # TODO: add block to the local store
    return blk.some.success
  except CatchableError as exc:
    trace "Exception requesting block", cid, exc = exc.msg
    return failure(exc)

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

proc new*(
  T: type NetworkStore,
  engine: BlockExcEngine,
  localStore: BlockStore): T =

  let b = NetworkStore(
    localStore: localStore,
    engine: engine)

  return b
