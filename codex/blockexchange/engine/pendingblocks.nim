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

import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/libp2p
import pkg/metrics

import ../../blocktype
import ../protobuf/blockexc

import ../../merkletree

logScope:
  topics = "codex pendingblocks"

declareGauge(codexBlockExchangePendingBlockRequests, "codex blockexchange pending block requests")

const
  DefaultBlockTimeout* = 10.minutes

# TODO change bool fields delivered/inflight to enum

type
  BlockReq* = object
    handle*: Future[Block]
    inFlight*: bool

  LeafReq* = object
    handle*: Future[Block]
    inFlight*: bool
    case delivered*: bool
    of true:
      proof*: MerkleProof
    else:
      discard

  TreeReq* = ref object
    leaves*: Table[Natural, LeafReq] # TODO consider seq
    treeHandle*: Future[MerkleTree]
    awaitCount*: Natural
    merkleRoot*: MultiHash
    treeCid*: Cid

  PendingBlocksManager* = ref object of RootObj
    blocks*: Table[Cid, BlockReq] # pending Block requests
    trees*: Table[Cid, TreeReq]

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  codexBlockExchangePendingBlockRequests.set(p.blocks.len.int64)

proc getWantHandle*(
    treeReq: TreeReq,
    index: Natural,
    timeout = DefaultBlockTimeout
): Future[Block] {.async.} =
  if not index in treeReq.leaves:
    let value = LeafReq(
      handle: newFuture[Block]("pendingBlocks.getWantHandle"),
      inFlight: false,
      delivered: false
    )
    # discard value # TODO wtf?
    treeReq.leaves[index] = value

  try:
    return await treeReq.leaves[index].handle.wait(timeout)
  except CancelledError as exc:
    trace "Blocks cancelled", exc = exc.msg, treeCid = treeReq.treeCid, index = index
    raise exc
  except CatchableError as exc:
    trace "Pending WANT failed or expired", exc = exc.msg, treeCid = treeReq.treeCid, index = index
    raise exc
  finally:
    discard
    # TODO handle gc-ing leafs
    # p.blocks.del(cid)
    # p.updatePendingBlockGauge()
  
proc getOrPutTreeReq*(
  p: PendingBlocksManager,
  treeCid: Cid,
  leavesCount: Natural,
  merkleRoot: MultiHash,
): ?!TreeReq =
  if treeCid notin p.trees:
    var value = TreeReq(
        treeHandle: newFuture[MerkleTree]("pendingBlocks.getWantHandle"),
        merkleRoot: merkleRoot,
        awaitCount: leavesCount,
        treeCid: treeCid
      )
    p.trees[treeCid] = value
    return success(value)
  else:
    try:
      let req = p.trees[treeCid]
      if req.merkleRoot == merkleRoot and
        req.awaitCount <= leavesCount:
        return success(req)
      else:
        return failure("Unexpected root or leaves count for tree with cid " & $treeCid)
    except CatchableError as err: #TODO fixit
      return failure("fdafafds")

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
        inFlight: inFlight)

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
              blocksDelivery: seq[BlockDelivery]) =
  ## Resolve pending blocks
  ##

  for bd in blocksDelivery:
    p.blocks.withValue(bd.blk.cid, pending):
      if not pending[].handle.completed:
        trace "Resolving block", cid = bd.blk.cid
        pending[].handle.complete(bd.blk)

    # resolve any pending blocks
    if bd.address.leaf:
      p.trees.withValue(bd.address.treeCid, treeReq):
        treeReq[].leaves.withValue(bd.address.index, leafReq):
          if not leafReq[].handle.completed: # TODO verify merkle proof
            trace "Resolving leaf block", cid = bd.blk.cid
            leafReq[].handle.complete(bd.blk) # TODO replace it with new future -> load blk from store by cid
            leafReq[].proof = bd.proof # TODO fix it
            leafReq[].delivered = true
          dec treeReq[].awaitCount

    # TODO if last block produce a merkle tree and save it into the local store and GC everything and run "queueProvideBlocksReq"

proc setInFlight*(p: PendingBlocksManager,
                  cid: Cid,
                  inFlight = true) =
  p.blocks.withValue(cid, pending):
    pending[].inFlight = inFlight
    trace "Setting inflight", cid, inFlight = pending[].inFlight

proc setInFlight*(treeReq: TreeReq,
                  index: Natural,
                  inFlight = true) =
  treeReq.leaves.withValue(index, leafReq):
    leafReq[].inFlight = inFlight
    # pending[].inFlight = inFlight
    # TODO 
    trace "Setting inflight", treeCid = treeReq.treeCid, index, inFlight = inFlight

proc isInFlight*(treeReq: TreeReq,
                 index: Natural
                ): bool =
  treeReq.leaves.withValue(index, leafReq):
    return leafReq[].inFlight
  # treeReq.leaves.?[index].?inFlight ?| false
  # p.blocks.withValue(cid, pending):
  #   result = pending[].inFlight
  #   trace "Getting inflight", cid, inFlight = result

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

iterator wantList*(p: PendingBlocksManager): BlockAddress =
  for k in p.blocks.keys:
    yield BlockAddress(leaf: false, cid: k)
  
  for treeCid, treeReq in p.trees.pairs:
    for index, leafReq in treeReq.leaves.pairs:
      if not leafReq.delivered: 
        yield BlockAddress(leaf: true, treeCid: treeCid, index: index)

# TODO rename to `discoveryCids`
iterator wantListCids*(p: PendingBlocksManager): Cid =
  for k in p.blocks.keys:
    yield k

  for k in p.trees.keys:
    yield k

# TODO remove it?
iterator wantHandles*(p: PendingBlocksManager): Future[Block] =
  for v in p.blocks.values:
    yield v.handle

func len*(p: PendingBlocksManager): int =
  p.blocks.len

func new*(T: type PendingBlocksManager): PendingBlocksManager =
  PendingBlocksManager()
