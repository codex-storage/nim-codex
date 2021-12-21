## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import ../blocktype as bt
import ../utils/asyncheapqueue

import ./blockstore
import ../blockexchange/network
import ../blockexchange/engine
import ../blockexchange/peercontext

export blockstore, network, engine, asyncheapqueue

logScope:
  topics = "dagger networkstore"

type
  NetworkStore* = ref object of BlockStore
    engine*: BlockExcEngine # blockexc decision engine
    localStore*: BlockStore # local block store

method getBlock*(
  self: NetworkStore,
  cid: Cid): Future[?bt.Block] {.async.} =
  ## Get a block from a remote peer
  ##

  trace "Getting block", cid
  without blk =? (await self.localStore.getBlock(cid)):
    trace "Couldn't get from local store", cid
    return await self.engine.requestBlock(cid)

  trace "Retrieved block from local store", cid
  return blk.some

method putBlock*(
  self: NetworkStore,
  blk: bt.Block): Future[bool] {.async.} =
  trace "Puting block", cid = blk.cid

  if not (await self.localStore.putBlock(blk)):
    return false

  self.engine.resolveBlocks(@[blk])
  return true

method delBlock*(
  self: NetworkStore,
  cid: Cid): Future[bool] =
  ## Delete a block/s from the block store
  ##

  self.localStore.delBlock(cid)

{.pop.}

method hasBlock*(
  self: NetworkStore,
  cid: Cid): bool =
  ## Check if the block exists in the blockstore
  ##

  self.localStore.hasBlock(cid)

proc new*(
  T: type NetworkStore,
  engine: BlockExcEngine,
  localStore: BlockStore): T =

  let b = NetworkStore(
    localStore: localStore,
    engine: engine)

  return b
