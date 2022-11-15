## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables

import pkg/upraises

push: {.upraises: [].}

import pkg/questionable
import pkg/chronicles
import pkg/chronos
import pkg/libp2p

import ../../blocktype

logScope:
  topics = "codex blockexc pendingblocks"

const
  DefaultBlockTimeout* = 10.minutes

type
  BlockReq* = object
    handle*: Future[Block]
    inFlight*: bool

  PendingBlocksManager* = ref object of RootObj
    blocks*: Table[Cid, BlockReq] # pending Block requests

proc getWantHandle*(
  p: PendingBlocksManager,
  cid: Cid,
  timeout = DefaultBlockTimeout,
  inFlight = false): Future[Block] {.async.} =
  ## Add an event for a block
  ##

  try:
    if cid notin p.blocks:
      p.blocks[cid] = BlockReq(
        handle: newFuture[Block]("pendingBlocks.getWantHandle"),
        inFlight: inFlight)

      trace "Adding pending future for block", cid

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

proc resolve*(
  p: PendingBlocksManager,
  blocks: seq[Block]) =
  ## Resolve pending blocks
  ##

  for blk in blocks:
    # resolve any pending blocks
    p.blocks.withValue(blk.cid, pending):
      if not pending[].handle.completed:
        trace "Resolving block", cid = blk.cid
        pending[].handle.complete(blk)

proc setInFlight*(
  p: PendingBlocksManager,
  cid: Cid) =
  p.blocks.withValue(cid, pending):
    pending[].inFlight = true

proc isInFlight*(
  p: PendingBlocksManager,
  cid: Cid): bool =
  p.blocks.withValue(cid, pending):
    result = pending[].inFlight

proc pending*(
  p: PendingBlocksManager,
  cid: Cid): bool = cid in p.blocks

proc contains*(
  p: PendingBlocksManager,
  cid: Cid): bool = p.pending(cid)

iterator wantList*(p: PendingBlocksManager): Cid =
  for k in p.blocks.keys:
    yield k

iterator wantHandles*(p: PendingBlocksManager): Future[Block] =
  for v in p.blocks.values:
    yield v.handle

func len*(p: PendingBlocksManager): int =
  p.blocks.len

func new*(T: type PendingBlocksManager): T =
  T()
