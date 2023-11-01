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
import pkg/questionable/results

import ../protobuf/blockexc
import ../../blocktype
import ../../merkletree

logScope:
  topics = "codex pendingblocks"

declareGauge(codexBlockExchangePendingBlockRequests, "codex blockexchange pending block requests")
declareGauge(codexBlockExchangeRetrievalTimeUs, "codex blockexchange block retrieval time us")

const
  DefaultBlockTimeout* = 10.minutes

type
  BlockReq* = object
    handle*: Future[Block]
    inFlight*: bool
    startTime*: int64

  PendingBlocksManager* = ref object of RootObj
    blocks*: Table[BlockAddress, BlockReq] # pending Block requests

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  codexBlockExchangePendingBlockRequests.set(p.blocks.len.int64)

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

      if bd.address.leaf:
        without proof =? bd.proof:
          warn "Missing proof for a block", address = bd.address
          continue
        
        if proof.index != bd.address.index:
          warn "Proof index doesn't match leaf index", address = bd.address, proofIndex = proof.index
          continue

        without leaf =? bd.blk.cid.mhash.mapFailure, err:
          error "Unable to get mhash from cid for block", address = bd.address, msg = err.msg
          continue

        without treeRoot =? bd.address.treeCid.mhash.mapFailure, err:
          error "Unable to get mhash from treeCid for block", address = bd.address, msg = err.msg
          continue

        without verifyOutcome =? proof.verifyLeaf(leaf, treeRoot), err:
          error "Unable to verify proof for block", address = bd.address, msg = err.msg
          continue

        if not verifyOutcome:
          warn "Invalid proof provided for a block", address = bd.address
      else: # bd.address.leaf == false
        if bd.address.cid != bd.blk.cid:
          warn "Delivery cid doesn't match block cid", deliveryCid = bd.address.cid, blockCid = bd.blk.cid
          continue

      let
        startTime = blockReq.startTime
        stopTime = getMonoTime().ticks
        retrievalDurationUs = (stopTime - startTime) div 1000

      blockReq.handle.complete(bd.blk)
      
      codexBlockExchangeRetrievalTimeUs.set(retrievalDurationUs)
      trace "Block retrieval time", retrievalDurationUs
    do:
      warn "Attempting to resolve block delivery for not pending block", address = bd.address

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
  for k in p.blocks.keys:
    yield k.cidOrTreeCid # TODO don't yield duplicates


iterator wantHandles*(p: PendingBlocksManager): Future[Block] =
  for v in p.blocks.values:
    yield v.handle

proc wantListLen*(p: PendingBlocksManager): int =
  p.blocks.len

func len*(p: PendingBlocksManager): int =
  p.blocks.len

func new*(T: type PendingBlocksManager): PendingBlocksManager =
  PendingBlocksManager()
