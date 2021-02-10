## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/hashes
import std/heapqueue
import std/options
import std/tables
import std/sequtils
import std/heapqueue

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import ./protobuf/bitswap as pb
import ../blocktype as bt
import ../store/blockstore
import ../utils/asyncheapqueue

import ./network
import ./engine

const
  DefaultTaskQueueSize = 100

type
  Bitswap* = ref object of BlockProvider
    engine: BitswapEngine                       # bitswap decision engine
    tasksQueue: AsyncHeapQueue[BitswapPeerCtx]  # peers we're currently processing tasks for
    # TODO: probably a good idea to have several
    # tasks running in parallel
    bitswapTask: Future[void]                   # future to control bitswap task
    bitswapRunning: bool                        # indicates if the bitswap task is running

method getBlock*(b: Bitswap, cid: Cid | seq[Cid]): Future[seq[bt.Block]] =
  ## Get a block from a remote peer
  ##

  b.engine.requestBlocks(cid)

proc bitswapTaskRunner(b: Bitswap) {.async.} =
  discard
  # while b.bitswapRunning:
  #   let peerCtx = await b.tasksQueue.pop()
  #   var wants: seq[Entry]
  #   for entry in peerCtx.peerWants:
  #     discard

proc start*(b: Bitswap) {.async.} =
  ## Start the bitswap task
  ##

  trace "bitswap start"

  if not b.bitswapTask.isNil:
    warn "Starting bitswap twice"
    return

  b.bitswapRunning = true
  b.bitswapTask = b.bitswapTaskRunner

proc stop*(b: Bitswap) {.async.} =
  ## Stop the bitswap bitswap
  ##

  trace "bitswap stop"
  if b.bitswapTask.isNil:
    warn "Stopping bitswap without starting it"
    return

  b.bitswapRunning = false
  if not b.bitswapTask.finished:
    trace "awaiting last task"
    await b.bitswapTask
    trace "bitswap stopped"
    b.bitswapTask = nil

proc new*(T: type Bitswap, store: BlockStore, network: BitswapNetwork): T =
  Bitswap(
    engine: BitswapEngine.new(store, network),
    taskQueue: newAsyncHeapQueue[BitswapPeerCtx]()
  )
