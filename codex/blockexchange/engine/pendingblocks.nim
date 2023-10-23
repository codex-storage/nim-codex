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

import ../../blocktype
import pkg/chronicles
import pkg/questionable
import pkg/questionable/options
import pkg/questionable/results
import pkg/chronos
import pkg/libp2p
import pkg/metrics
import pkg/questionable/results

import ../protobuf/blockexc
import ../../blocktype
import ../../merkletree

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

  TreeHandler* = proc(tree: MerkleTree): Future[void] {.raises:[], gcsafe.}

  PendingBlocksManager* = ref object of RootObj
    blocks*: Table[BlockAddress, BlockReq] # pending Block requests

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  codex_block_exchange_pending_block_requests.set(p.blocks.len.int64)

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
    asyncSpawn p.onTree(tree)

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
    address: BlockAddress,
    timeout = DefaultBlockTimeout,
    inFlight = false
): Future[Block] {.async.} =
  ## Add an event for a block
  ##

  try:
    if address notin p.blocks:
      p.blocks[address] = BlockReq(
        handle: newFuture[Block]("pendingBlocks.getWantHandle"),
        inFlight: inFlight,
        startTime: getMonoTime().ticks)

      trace "Adding pending future for block", address, inFlight = p.blocks[address].inFlight

    p.updatePendingBlockGauge()
    return await p.blocks[address].handle.wait(timeout)
  except CancelledError as exc:
    trace "Blocks cancelled", exc = exc.msg, address
    raise exc
  except CatchableError as exc:
    trace "Pending WANT failed or expired", exc = exc.msg
    # no need to cancel, it is already cancelled by wait()
    raise exc
  finally:
    p.blocks.del(address)
    p.updatePendingBlockGauge()

proc getWantHandle*(
    p: PendingBlocksManager,
    cid: Cid,
    timeout = DefaultBlockTimeout,
    inFlight = false
): Future[Block] =
  p.getWantHandle(BlockAddress.init(cid), timeout, inFlight)

proc resolve*(
  p: PendingBlocksManager,
  blocksDelivery: seq[BlockDelivery]
  ) {.gcsafe, raises: [].} =
  ## Resolve pending blocks
  ##

  for bd in blocksDelivery:
    p.blocks.withValue(bd.address, blockReq):
      trace "Resolving block", address = bd.address

      if not blockReq.handle.finished:
        let
          startTime = blockReq.startTime
          stopTime = getMonoTime().ticks
          retrievalDurationUs = (stopTime - startTime) div 1000

        blockReq.handle.complete(bd.blk)
        
        codex_block_exchange_retrieval_time_us.set(retrievalDurationUs)
        trace "Block retrieval time", retrievalDurationUs, address = bd.address
      else:
        trace "Block handle already finished", address = bd.address
    do:
      warn "Attempting to resolve block that's not currently a pending block", address = bd.address

proc setInFlight*(p: PendingBlocksManager,
                  address: BlockAddress,
                  inFlight = true) =
  p.blocks.withValue(address, pending):
    pending[].inFlight = inFlight
    trace "Setting inflight", address, inFlight = pending[].inFlight

proc isInFlight*(p: PendingBlocksManager,
                 address: BlockAddress,
                ): bool =
  p.blocks.withValue(address, pending):
    result = pending[].inFlight
    trace "Getting inflight", address, inFlight = result

proc contains*(p: PendingBlocksManager, cid: Cid): bool =
  BlockAddress.init(cid) in p.blocks

proc contains*(p: PendingBlocksManager, address: BlockAddress): bool =
  address in p.blocks

iterator wantList*(p: PendingBlocksManager): BlockAddress =
  for a in p.blocks.keys:
    yield a

iterator wantListBlockCids*(p: PendingBlocksManager): Cid =
  for a in p.blocks.keys:
    if not a.leaf:
      yield a.cid

iterator wantListCids*(p: PendingBlocksManager): Cid =
  var yieldedCids = initHashSet[Cid]()
  for a in p.blocks.keys:
    let cid = a.cidOrTreeCid
    if cid notin yieldedCids:
      yieldedCids.incl(cid)
      yield cid


iterator wantHandles*(p: PendingBlocksManager): Future[Block] =
  for v in p.blocks.values:
    yield v.handle

proc wantListLen*(p: PendingBlocksManager): int =
  p.blocks.len

func len*(p: PendingBlocksManager): int =
  p.blocks.len

func new*(T: type PendingBlocksManager): PendingBlocksManager =
  PendingBlocksManager()
