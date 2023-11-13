## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/monotimes

import pkg/upraises

push: {.upraises: [].}

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/metrics

import ../../blocktype

logScope:
  topics = "codex pendingblocks"

declareGauge(codex_block_exchange_pending_block_requests, "codex blockexchange pending block requests")
declareGauge(codex_block_exchange_retrieval_time_us, "codex blockexchange block retrieval time us")

const
  DefaultBlockTimeout* = 10.minutes

type
  BlockReq* = object
    handle*: Future[Block]
    inFlight*: bool
    startTime*: int64

  PendingBlocksManager* = ref object of RootObj
    blocks*: Table[Cid, BlockReq] # pending Block requests

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  codex_block_exchange_pending_block_requests.set(p.blocks.len.int64)

proc getWantHandle*(
    p: PendingBlocksManager,
    cid: Cid,
    timeout = DefaultBlockTimeout,
    inFlight = false
): Future[Block] {.async.} =
  ## Add an event for a block
  ##

  try:
    if cid notin p.blocks:
      p.blocks[cid] = BlockReq(
        handle: newFuture[Block]("pendingBlocks.getWantHandle"),
        inFlight: inFlight,
        startTime: getMonoTime().ticks)

      trace "Adding pending future for block", cid, inFlight = p.blocks[cid].inFlight

    p.updatePendingBlockGauge()
    return await p.blocks[cid].handle.wait(timeout)
  except CancelledError as exc:
    trace "Blocks cancelled", exc = exc.msg, cid
    raise exc
  except CatchableError as exc:
    trace "Pending WANT failed or expired", exc = exc.msg
    # no need to cancel, it is already cancelled by wait()
    raise exc
  finally:
    p.blocks.del(cid)
    p.updatePendingBlockGauge()

proc resolve*(p: PendingBlocksManager,
              blocks: seq[Block]) =
  ## Resolve pending blocks
  ##

  for blk in blocks:
    # resolve any pending blocks
    p.blocks.withValue(blk.cid, pending):
      if not pending[].handle.completed:
        trace "Resolving block", cid = blk.cid
        pending[].handle.complete(blk)
        let
          startTime = pending[].startTime
          stopTime = getMonoTime().ticks
          retrievalDurationUs = (stopTime - startTime) div 1000
        codex_block_exchange_retrieval_time_us.set(retrievalDurationUs)
        trace "Block retrieval time", retrievalDurationUs

proc setInFlight*(p: PendingBlocksManager,
                  cid: Cid,
                  inFlight = true) =
  p.blocks.withValue(cid, pending):
    pending[].inFlight = inFlight
    trace "Setting inflight", cid, inFlight = pending[].inFlight

proc isInFlight*(p: PendingBlocksManager,
                 cid: Cid
                ): bool =
  p.blocks.withValue(cid, pending):
    result = pending[].inFlight
    trace "Getting inflight", cid, inFlight = result

proc pending*(p: PendingBlocksManager, cid: Cid): bool =
  cid in p.blocks

proc contains*(p: PendingBlocksManager, cid: Cid): bool =
  p.pending(cid)

iterator wantList*(p: PendingBlocksManager): Cid =
  for k in p.blocks.keys:
    yield k

iterator wantHandles*(p: PendingBlocksManager): Future[Block] =
  for v in p.blocks.values:
    yield v.handle

func len*(p: PendingBlocksManager): int =
  p.blocks.len

func new*(T: type PendingBlocksManager): PendingBlocksManager =
  PendingBlocksManager()
