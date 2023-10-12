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

import ../../blocktype
import pkg/chronicles
import pkg/questionable
import pkg/questionable/options
import pkg/questionable/results
import pkg/chronos
import pkg/libp2p
import pkg/metrics

import ../protobuf/blockexc

import ../../merkletree
import ../../utils

logScope:
  topics = "codex pendingblocks"

declareGauge(codexBlockExchangePendingBlockRequests, "codex blockexchange pending block requests")

const
  DefaultBlockTimeout* = 10.minutes

type
  BlockReq* = object
    handle*: Future[Block]
    inFlight*: bool

  LeafReq* = object
    case delivered*: bool
    of false:
      handle*: Future[Block]
      inFlight*: bool
    of true:
      leaf: MultiHash
      blkCid*: Cid

  TreeReq* = ref object
    leaves*: Table[Natural, LeafReq]
    deliveredCount*: Natural
    leavesCount*: ?Natural
    treeRoot*: MultiHash
    treeCid*: Cid

  TreeHandler* = proc(tree: MerkleTree): Future[void] {.gcsafe.}

  PendingBlocksManager* = ref object of RootObj
    blocks*: Table[Cid, BlockReq] # pending Block requests
    trees*: Table[Cid, TreeReq]
    onTree*: TreeHandler

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  codexBlockExchangePendingBlockRequests.set(p.blocks.len.int64)

type 
  BlockHandleOrCid = object
    case resolved*: bool
    of true:
      cid*: Cid
    else:
      handle*: Future[Block]

proc buildTree(treeReq: TreeReq): ?!MerkleTree =
  trace "Building a merkle tree from leaves", treeCid = treeReq.treeCid, leavesCount = treeReq.leavesCount

  without leavesCount =? treeReq.leavesCount:
    return failure("Leaves count is none, cannot build a tree")

  var builder = ? MerkleTreeBuilder.init(treeReq.treeRoot.mcodec)
  for i in 0..<leavesCount:
    treeReq.leaves.withValue(i, leafReq):
      if leafReq.delivered:
        ? builder.addLeaf(leafReq.leaf)
      else:
        return failure("Expected all leaves to be delivered but leaf with index " & $i & " was not")
    do:
      return failure("Missing a leaf with index " & $i)

  let tree = ? builder.build()

  if tree.root != treeReq.treeRoot:
    return failure("Reconstructed tree root doesn't match the original tree root, tree cid is " & $treeReq.treeCid)
 
  return success(tree)

proc checkIfAllDelivered(p: PendingBlocksManager, treeReq: TreeReq): void =
  if treeReq.deliveredCount.some == treeReq.leavesCount:
    without tree =? buildTree(treeReq), err:
      error "Error building a tree", msg = err.msg
      p.trees.del(treeReq.treeCid)
      return
    p.trees.del(treeReq.treeCid)
    try:
      asyncSpawn p.onTree(tree)
    except Exception as err:
      error "Exception when handling tree", msg = err.msg

proc getWantHandleOrCid*(
    treeReq: TreeReq,
    index: Natural,
    timeout = DefaultBlockTimeout
): BlockHandleOrCid =
  treeReq.leaves.withValue(index, leafReq):
    if not leafReq.delivered:
      return BlockHandleOrCid(resolved: false, handle: leafReq.handle)
    else:
      return BlockHandleOrCid(resolved: true, cid: leafReq.blkCid)
  do:
    let leafReq = LeafReq(
      delivered: false,
      handle: newFuture[Block]("pendingBlocks.getWantHandleOrCid"),
      inFlight: false
    )
    treeReq.leaves[index] = leafReq
    return BlockHandleOrCid(resolved: false, handle: leafReq.handle)
  
proc getOrPutTreeReq*(
  p: PendingBlocksManager,
  treeCid: Cid,
  leavesCount = Natural.none, # has value when all leaves are expected to be delivered
  treeRoot: MultiHash
): ?!TreeReq =
  p.trees.withValue(treeCid, treeReq):
    if treeReq.treeRoot != treeRoot:
      return failure("Unexpected root for tree with cid " & $treeCid)

    if leavesCount == treeReq.leavesCount:
      return success(treeReq[])
    else:
      treeReq.leavesCount = treeReq.leavesCount.orElse(leavesCount)
      let res = success(treeReq[])
      p.checkIfAllDelivered(treeReq[])
      return res
  do:
    let treeReq = TreeReq(
        deliveredCount: 0,
        leavesCount: leavesCount,
        treeRoot: treeRoot,
        treeCid: treeCid
      )
    p.trees[treeCid] = treeReq
    return success(treeReq)

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

proc getOrComputeLeaf(mcodec: MultiCodec, blk: Block): ?!MultiHash =
  without mhash =? blk.cid.mhash.mapFailure, err:
    return MultiHash.digest($mcodec, blk.data).mapFailure
  
  if mhash.mcodec == mcodec:
    return success(mhash)
  else:
    return MultiHash.digest($mcodec, blk.data).mapFailure

proc resolve*(
  p: PendingBlocksManager,
  blocksDelivery: seq[BlockDelivery]
  ) {.gcsafe, raises: [].} =
  ## Resolve pending blocks
  ##

  for bd in blocksDelivery:

    if not bd.address.leaf:
      if bd.address.cid == bd.blk.cid:
        p.blocks.withValue(bd.blk.cid, pending):
          if not pending.handle.completed:
            trace "Resolving block", cid = bd.blk.cid
            pending.handle.complete(bd.blk)
      else:
        warn "Delivery cid doesn't match block cid", deliveryCid = bd.address.cid, blockCid = bd.blk.cid

    # resolve any pending blocks
    if bd.address.leaf:
      p.trees.withValue(bd.address.treeCid, treeReq):
        treeReq.leaves.withValue(bd.address.index, leafReq):
          if not leafReq.delivered:
            if proof =? bd.proof:
              if not proof.index == bd.address.index:
                warn "Proof index doesn't match leaf index", address = bd.address, proofIndex = proof.index
                continue
              without mhash =? bd.blk.cid.mhash.mapFailure, err:
                error "Unable to get mhash from cid for block", address = bd.address, msg = err.msg
                continue
              without verifySuccess =? proof.verifyLeaf(mhash, treeReq.treeRoot), err:
                error "Unable to verify proof for block", address = bd.address, msg = err.msg
                continue
              if verifySuccess:
                without leaf =? getOrComputeLeaf(treeReq.treeRoot.mcodec, bd.blk), err:
                  error "Unable to get or calculate hash for block", address = bd.address
                  continue

                leafReq.handle.complete(bd.blk)
                leafReq[] = LeafReq(delivered: true, blkCid: bd.blk.cid, leaf: leaf)

                inc treeReq.deliveredCount

                p.checkIfAllDelivered(treeReq[])
              else:
                warn "Invalid proof provided for a block", address = bd.address
            else:
              warn "Missing proof for a block", address = bd.address
          else:
            trace "Ignore veryfing proof for already delivered block", address = bd.address

proc setInFlight*(p: PendingBlocksManager,
                  cid: Cid,
                  inFlight = true) =
  p.blocks.withValue(cid, pending):
    pending.inFlight = inFlight
    trace "Setting inflight", cid, inFlight = pending.inFlight

proc trySetInFlight*(treeReq: TreeReq,
                  index: Natural,
                  inFlight = true) =
  treeReq.leaves.withValue(index, leafReq):
    if not leafReq.delivered:
      leafReq.inFlight = inFlight
      trace "Setting inflight", treeCid = treeReq.treeCid, index, inFlight = inFlight

proc isInFlight*(treeReq: TreeReq,
                 index: Natural
                ): bool =
  treeReq.leaves.withValue(index, leafReq):
    return (not leafReq.delivered) and leafReq.inFlight
  do:
    return false

proc isInFlight*(p: PendingBlocksManager,
                 cid: Cid
                ): bool =
  p.blocks.withValue(cid, pending):
    result = pending.inFlight
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

iterator wantListBlockCids*(p: PendingBlocksManager): Cid =
  for k in p.blocks.keys:
    yield k

iterator wantListCids*(p: PendingBlocksManager): Cid =
  for k in p.blocks.keys:
    yield k

  for k in p.trees.keys:
    yield k

iterator wantHandles*(p: PendingBlocksManager): Future[Block] =
  for v in p.blocks.values:
    yield v.handle


proc wantListLen*(p: PendingBlocksManager): int =
  p.blocks.len + p.trees.len

func len*(p: PendingBlocksManager): int =
  p.blocks.len

func new*(T: type PendingBlocksManager): PendingBlocksManager =
  PendingBlocksManager()
