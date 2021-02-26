## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables

import pkg/chronicles
import pkg/chronos
import pkg/libp2p

import ../blocktype

logScope:
  topics = "dagger bitswap pendingblocks"

type
  PendingBlocksManager* = ref object of RootObj
    blocks*: Table[Cid, Future[Block]] # pending Block requests

proc addOrAwait*(
  p: PendingBlocksManager,
  cid: Cid):
  Future[Block] {.async.} =
  ## Add an event for a block
  ##

  if cid notin p.blocks:
     p.blocks[cid] = newFuture[Block]()
     trace "Adding pending future for block", cid

  let blk = p.blocks[cid]
  try:
    return await blk
  except CancelledError as exc:
    trace "Blocks cancelled", exc = exc.msg, cid
    raise exc
  except CatchableError as exc:
    trace "Pending WANT failed or expired", exc = exc.msg
  finally:
    p.blocks.del(cid)

proc resolve*(
  p: PendingBlocksManager,
  blocks: seq[Block]) =
  ## Resolve pending blocks
  ##

  for blk in blocks:
    # resolve any pending blocks
    if blk.cid in p.blocks:
      let pending = p.blocks[blk.cid]
      if not pending.finished:
        trace "Resolving block", cid = $blk.cid
        pending.complete(blk)
        p.blocks.del(blk.cid)

proc pending*(
  p: PendingBlocksManager,
  cid: Cid): bool = cid in p.blocks

proc contains*(
  p: PendingBlocksManager,
  cid: Cid): bool = p.pending(cid)

proc new*(T: type PendingBlocksManager): T =
  T(
    blocks: initTable[Cid, Future[Block]]()
  )
