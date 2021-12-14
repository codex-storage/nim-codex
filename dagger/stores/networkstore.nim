## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

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
import ../blockexchange/protobuf/blockexc as pb

export blockstore, network, engine, asyncheapqueue

logScope:
  topics = "dagger networkstore"

type
  NetworkStore* = ref object of BlockStore
    engine*: BlockExcEngine                       # blockexc decision engine
    localStore*: BlockStore                       # local block store

method getBlock*(
  b: NetworkStore,
  cid: Cid): Future[?bt.Block] {.async.} =
  ## Get a block from a remote peer
  ##

  trace "Getting block", cid
  without blk =? (await b.localStore.getBlock(cid)):
    trace "Couldn't get from local store", cid
    return await b.engine.requestBlock(cid)

  trace "Retrieved block from local store", cid
  return blk.some

method putBlock*(
  b: NetworkStore,
  blk: bt.Block) {.async.} =
  trace "Puting block", cid = blk.cid
  await b.localStore.putBlock(blk)
  b.engine.resolveBlocks(@[blk])

proc new*(
  T: type NetworkStore,
  engine: BlockExcEngine,
  localStore: BlockStore): T =

  let b = NetworkStore(
    localStore: localStore,
    engine: engine)

  return b
