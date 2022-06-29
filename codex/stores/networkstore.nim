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

method getBlock*(
  self: NetworkStore,
  cid: Cid): Future[?!bt.Block] {.async.} =
  ## Get a block from a remote peer
  ##

  trace "Getting block", cid
  without var blk =? (await self.localStore.getBlock(cid)):
    trace "Couldn't get from local store", cid
    try:
      blk = await self.engine.requestBlock(cid)
    except CatchableError as exc:
      trace "Exception requesting block", cid, exc = exc.msg
      return failure(exc.msg)

  trace "Retrieved block from local store", cid
  return blk.success

method putBlock*(
  self: NetworkStore,
  blk: bt.Block): Future[bool] {.async.} =
  ## Store block locally and notify the
  ## network
  ##

  trace "Puting block", cid = blk.cid

  if not (await self.localStore.putBlock(blk)):
    return false

  await self.engine.resolveBlocks(@[blk])
  return true

method delBlock*(
  self: NetworkStore,
  cid: Cid): Future[?!void] =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block from networkstore", cid
  return self.localStore.delBlock(cid)

{.pop.}

method hasBlock*(self: NetworkStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking NetworkStore for block existence", cid
  return await self.localStore.hasBlock(cid)

proc new*(
  T: type NetworkStore,
  engine: BlockExcEngine,
  localStore: BlockStore): T =

  let b = NetworkStore(
    localStore: localStore,
    engine: engine)

  return b
