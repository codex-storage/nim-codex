## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/tables
import std/monotimes
import std/strutils

import pkg/chronos
import pkg/libp2p
import pkg/metrics

import ../protobuf/blockexc
import ../../blocktype
import ../../logutils

logScope:
  topics = "codex pendingblocks"

declareGauge(
  codex_block_exchange_pending_block_requests,
  "codex blockexchange pending block requests",
)
declareGauge(
  codex_block_exchange_retrieval_time_us, "codex blockexchange block retrieval time us"
)

const
  DefaultBlockRetries* = 3000
  DefaultRetryInterval* = 2.seconds

type
  RetriesExhaustedError* = object of CatchableError
  BlockHandle* = Future[Block].Raising([CancelledError, RetriesExhaustedError])

  BlockReq* = object
    handle*: BlockHandle
    requested*: ?PeerId
    blockRetries*: int
    startTime*: int64

  PendingBlocksManager* = ref object of RootObj
    blockRetries*: int = DefaultBlockRetries
    retryInterval*: Duration = DefaultRetryInterval
    blocks*: Table[BlockAddress, BlockReq] # pending Block requests
    lastInclusion*: Moment # time at which we last included a block into our wantlist

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  codex_block_exchange_pending_block_requests.set(p.blocks.len.int64)

proc getWantHandle*(
    self: PendingBlocksManager, address: BlockAddress, requested: ?PeerId = PeerId.none
): Future[Block] {.async: (raw: true, raises: [CancelledError, RetriesExhaustedError]).} =
  ## Add an event for a block
  ##

  self.blocks.withValue(address, blk):
    return blk[].handle
  do:
    let blk = BlockReq(
      handle: newFuture[Block]("pendingBlocks.getWantHandle"),
      requested: requested,
      blockRetries: self.blockRetries,
      startTime: getMonoTime().ticks,
    )
    self.blocks[address] = blk
    self.lastInclusion = Moment.now()

    let handle = blk.handle

    proc cleanUpBlock(data: pointer) {.raises: [].} =
      self.blocks.del(address)
      self.updatePendingBlockGauge()

    handle.addCallback(cleanUpBlock)
    handle.cancelCallback = proc(data: pointer) {.raises: [].} =
      if not handle.finished:
        handle.removeCallback(cleanUpBlock)
      cleanUpBlock(nil)

    self.updatePendingBlockGauge()
    return handle

proc getWantHandle*(
    self: PendingBlocksManager, cid: Cid, requested: ?PeerId = PeerId.none
): Future[Block] {.async: (raw: true, raises: [CancelledError, RetriesExhaustedError]).} =
  self.getWantHandle(BlockAddress.init(cid), requested)

proc completeWantHandle*(
    self: PendingBlocksManager, address: BlockAddress, blk: Block
) {.raises: [].} =
  ## Complete a pending want handle
  self.blocks.withValue(address, blockReq):
    if not blockReq[].handle.finished:
      trace "Completing want handle from provided block", address
      blockReq[].handle.complete(blk)
    else:
      trace "Want handle already completed", address
  do:
    trace "No pending want handle found for address", address

proc resolve*(
    self: PendingBlocksManager, blocksDelivery: seq[BlockDelivery]
) {.gcsafe, raises: [].} =
  ## Resolve pending blocks
  ##

  for bd in blocksDelivery:
    self.blocks.withValue(bd.address, blockReq):
      if not blockReq[].handle.finished:
        trace "Resolving pending block", address = bd.address
        let
          startTime = blockReq[].startTime
          stopTime = getMonoTime().ticks
          retrievalDurationUs = (stopTime - startTime) div 1000

        blockReq.handle.complete(bd.blk)

        codex_block_exchange_retrieval_time_us.set(retrievalDurationUs)
      else:
        trace "Block handle already finished", address = bd.address

func retries*(self: PendingBlocksManager, address: BlockAddress): int =
  self.blocks.withValue(address, pending):
    result = pending[].blockRetries
  do:
    result = 0

func decRetries*(self: PendingBlocksManager, address: BlockAddress) =
  self.blocks.withValue(address, pending):
    pending[].blockRetries -= 1

func retriesExhausted*(self: PendingBlocksManager, address: BlockAddress): bool =
  self.blocks.withValue(address, pending):
    result = pending[].blockRetries <= 0

func isRequested*(self: PendingBlocksManager, address: BlockAddress): bool =
  ## Check if a block has been requested to a peer
  ##
  result = false
  self.blocks.withValue(address, pending):
    result = pending[].requested.isSome

func getRequestPeer*(self: PendingBlocksManager, address: BlockAddress): ?PeerId =
  ## Returns the peer that requested this block
  ##
  result = PeerId.none
  self.blocks.withValue(address, pending):
    result = pending[].requested

proc markRequested*(
    self: PendingBlocksManager, address: BlockAddress, peer: PeerId
): bool =
  ## Marks this block as having been requested to a peer
  ##

  if self.isRequested(address):
    return false

  self.blocks.withValue(address, pending):
    pending[].requested = peer.some
  return true

proc clearRequest*(
    self: PendingBlocksManager, address: BlockAddress, peer: ?PeerId = PeerId.none
) =
  self.blocks.withValue(address, pending):
    if peer.isSome:
      assert peer == pending[].requested
    pending[].requested = PeerId.none

func contains*(self: PendingBlocksManager, cid: Cid): bool =
  BlockAddress.init(cid) in self.blocks

func contains*(self: PendingBlocksManager, address: BlockAddress): bool =
  address in self.blocks

iterator wantList*(self: PendingBlocksManager): BlockAddress =
  for a in self.blocks.keys:
    yield a

iterator wantListBlockCids*(self: PendingBlocksManager): Cid =
  for a in self.blocks.keys:
    if not a.leaf:
      yield a.cid

iterator wantListCids*(self: PendingBlocksManager): Cid =
  var yieldedCids = initHashSet[Cid]()
  for a in self.blocks.keys:
    let cid = a.cidOrTreeCid
    if cid notin yieldedCids:
      yieldedCids.incl(cid)
      yield cid

iterator wantHandles*(self: PendingBlocksManager): Future[Block] =
  for v in self.blocks.values:
    yield v.handle

proc wantListLen*(self: PendingBlocksManager): int =
  self.blocks.len

func len*(self: PendingBlocksManager): int =
  self.blocks.len

func new*(
    T: type PendingBlocksManager,
    retries = DefaultBlockRetries,
    interval = DefaultRetryInterval,
): PendingBlocksManager =
  PendingBlocksManager(blockRetries: retries, retryInterval: interval)
