## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, options, random]

import pkg/chronos
import pkg/libp2p/cid
import pkg/libp2p/peerid

import ./scheduler
import ./swarm
import ../peers/peercontext
import ../../storagetypes
import ../../blocktype
import ../protocol/message
import ../protocol/constants
import ../utils

export scheduler, peercontext

const
  PresenceWindowBytes*: uint64 = 1024 * 1024 * 1024
  PresenceWindowBlocks*: uint64 = PresenceWindowBytes div DefaultBlockSize.uint64
  MaxPresenceWindowBlocks*: uint64 = PresenceWindowBytes div MinBlockSize
  PresenceWindowThreshold*: float = 0.75
  PresenceBroadcastIntervalMin*: Duration = 5.seconds
  PresenceBroadcastIntervalMax*: Duration = 10.seconds
  PresenceBroadcastBlockThreshold*: uint64 = PresenceWindowBlocks div 2

static:
  const
    worstCaseRanges = MaxPresenceWindowBlocks div 2
    worstCasePresenceBytes = worstCaseRanges * 16 + 1024 # +1KB safe overhead
  doAssert worstCasePresenceBytes < MaxMessageSize,
    "Presence window too large for MaxMessageSize with minimum block size. " &
      "Worst case: " & $worstCasePresenceBytes & " bytes, limit: " & $MaxMessageSize &
      " bytes"

type
  DownloadProgress* = object
    blocksCompleted*: uint64
    totalBlocks*: uint64
    bytesTransferred*: uint64

  DownloadDesc* = object
    treeCid*: Cid
    blockSize*: uint32
    startIndex*: uint64
    count*: uint64
    selectionPolicy*: SelectionPolicy
    isBackground*: bool
    fetchLocal*: bool

  BroadcastAvailabilityTracker = object
    case policy: SelectionPolicy
    of spSequential:
      lastBroadcastedWatermark: uint64
      lastBroadcastTime: Moment
      broadcastInterval: Duration
    of spRandomWindow:
      pendingRanges: seq[tuple[start: uint64, count: uint64]]

  DownloadContext* = ref object
    treeCid*: Cid
    blockSize*: uint32
    totalBlocks*: uint64
    received*: uint64
    blocksReturned*: uint64
    bytesReceived*: uint64
    scheduler*: Scheduler
    swarm*: Swarm
    inFlightBlocks*: Table[uint64, PeerId] # block index -> peer fetching it
    availabilityTracker: BroadcastAvailabilityTracker

proc computeWindowSize*(blockSize: uint32): uint64 =
  result = PresenceWindowBytes div blockSize.uint64
  if result == 0:
    result = 1

proc randomBroadcastInterval(): Duration =
  rand(
    PresenceBroadcastIntervalMin.milliseconds.int ..
      PresenceBroadcastIntervalMax.milliseconds.int
  ).milliseconds

proc shouldBroadcast(t: BroadcastAvailabilityTracker, watermark: uint64): bool =
  case t.policy
  of spRandomWindow:
    t.pendingRanges.len > 0
  of spSequential:
    let newBlocks = watermark - t.lastBroadcastedWatermark
    if newBlocks == 0:
      return false
    let timeSinceLast = Moment.now() - t.lastBroadcastTime
    newBlocks >= PresenceBroadcastBlockThreshold or timeSinceLast >= t.broadcastInterval

proc getRanges(
    t: BroadcastAvailabilityTracker, watermark: uint64
): seq[tuple[start: uint64, count: uint64]] =
  case t.policy
  of spRandomWindow:
    t.pendingRanges
  of spSequential:
    let count = watermark - t.lastBroadcastedWatermark
    if count > 0:
      @[(start: t.lastBroadcastedWatermark, count: count)]
    else:
      @[]

proc markBroadcasted(t: var BroadcastAvailabilityTracker, watermark: uint64) =
  case t.policy
  of spRandomWindow:
    t.pendingRanges.setLen(0)
  of spSequential:
    t.lastBroadcastedWatermark = watermark
    t.lastBroadcastTime = Moment.now()
    t.broadcastInterval = randomBroadcastInterval()

proc addPendingRange(
    t: var BroadcastAvailabilityTracker, range: tuple[start: uint64, count: uint64]
) =
  case t.policy
  of spRandomWindow:
    t.pendingRanges.add(range)
  of spSequential:
    discard

proc toDownloadDesc*(
    treeCid: Cid,
    totalBlocks: uint64,
    blockSize: uint32,
    selectionPolicy: SelectionPolicy = spSequential,
    isBackground: bool = false,
    fetchLocal: bool = false,
): DownloadDesc =
  DownloadDesc(
    treeCid: treeCid,
    blockSize: blockSize,
    startIndex: 0,
    count: totalBlocks,
    selectionPolicy: selectionPolicy,
    isBackground: isBackground,
    fetchLocal: fetchLocal,
  )

proc toDownloadDesc*(
    treeCid: Cid, startIndex: uint64, count: uint64, blockSize: uint32
): DownloadDesc =
  DownloadDesc(
    treeCid: treeCid, blockSize: blockSize, startIndex: startIndex, count: count
  )

proc toDownloadDesc*(address: BlockAddress, blockSize: uint32): DownloadDesc =
  DownloadDesc(
    treeCid: address.treeCid,
    blockSize: blockSize,
    startIndex: address.index.uint64,
    count: 1,
  )

proc currentPresenceWindow*(ctx: DownloadContext): tuple[start: uint64, count: uint64] =
  ctx.scheduler.currentPresenceWindow()

proc needsNextPresenceWindow*(ctx: DownloadContext): bool =
  ctx.scheduler.needsNextPresenceWindow()

proc advancePresenceWindow*(ctx: DownloadContext): tuple[start: uint64, count: uint64] =
  ctx.availabilityTracker.addPendingRange(ctx.scheduler.currentPresenceWindow())
  discard ctx.scheduler.advancePresenceWindow()
  ctx.scheduler.currentPresenceWindow()

proc new*(
    T: type DownloadContext, desc: DownloadDesc, missingBlocks: seq[uint64] = @[]
): DownloadContext =
  doAssert desc.blockSize > 0, "blockSize must be known at download creation"

  let
    totalBlocks = desc.startIndex + desc.count
    blockSize = desc.blockSize
    batchSize = computeBatchSize(blockSize)
    windowSize = computeWindowSize(blockSize)

  result = DownloadContext(
    treeCid: desc.treeCid,
    blockSize: blockSize,
    totalBlocks: totalBlocks,
    scheduler: Scheduler.new(),
    swarm: Swarm.new(),
    inFlightBlocks: initTable[uint64, PeerId](),
  )

  case desc.selectionPolicy
  of spSequential:
    result.availabilityTracker = BroadcastAvailabilityTracker(
      policy: spSequential,
      lastBroadcastedWatermark: 0,
      lastBroadcastTime: Moment.now(),
      broadcastInterval: randomBroadcastInterval(),
    )

    if missingBlocks.len > 0:
      result.scheduler.initFromIndices(
        missingBlocks, batchSize.uint64, windowSize, PresenceWindowThreshold
      )
    elif desc.count > batchSize.uint64:
      if desc.startIndex == 0:
        result.scheduler.init(
          desc.count, batchSize.uint64, windowSize, PresenceWindowThreshold
        )
      else:
        result.scheduler.initRange(
          desc.startIndex, desc.count, batchSize.uint64, windowSize,
          PresenceWindowThreshold,
        )
    else:
      var indices: seq[uint64] = @[]
      for i in desc.startIndex ..< desc.startIndex + desc.count:
        indices.add(i)
      result.scheduler.initFromIndices(
        indices, batchSize.uint64, windowSize, PresenceWindowThreshold
      )
  of spRandomWindow:
    result.availabilityTracker = BroadcastAvailabilityTracker(policy: spRandomWindow)
    result.scheduler.initRandomWindows(totalBlocks, batchSize.uint64, windowSize)

proc isComplete*(ctx: DownloadContext): bool =
  ctx.blocksReturned >= ctx.totalBlocks or ctx.received >= ctx.totalBlocks

proc markBlockReturned*(ctx: DownloadContext) =
  # mark that a block was returned to the consumer by the iterator
  ctx.blocksReturned += 1

proc markBatchReceived*(
    ctx: DownloadContext, start: uint64, count: uint64, totalBytes: uint64
) =
  ctx.received += count
  ctx.bytesReceived += totalBytes
  for i in start ..< start + count:
    ctx.inFlightBlocks.del(i)

proc markBatchInFlight*(
    ctx: DownloadContext, start: uint64, count: uint64, peerId: PeerId
) =
  for i in start ..< start + count:
    ctx.inFlightBlocks[i] = peerId

proc clearInFlightForPeer*(ctx: DownloadContext, peerId: PeerId) =
  var toRemove: seq[uint64] = @[]
  for blockIdx, peer in ctx.inFlightBlocks:
    if peer == peerId:
      toRemove.add(blockIdx)
  for blockIdx in toRemove:
    ctx.inFlightBlocks.del(blockIdx)

proc trimPresenceBeforeWatermark*(ctx: DownloadContext) =
  let watermark = ctx.scheduler.completedWatermark()

  for peerId in ctx.swarm.connectedPeers():
    let peerOpt = ctx.swarm.getPeer(peerId)
    if peerOpt.isSome:
      let peer = peerOpt.get()
      # only trim range-based availability
      if peer.availability.kind == bakRanges:
        var newRanges: seq[tuple[start: uint64, count: uint64]] = @[]
        for (start, count) in peer.availability.ranges:
          let rangeEnd = start + count
          if rangeEnd > watermark:
            # keep ranges not entirely below watermark
            newRanges.add((start, count))
        peer.availability = BlockAvailability.fromRanges(newRanges)

proc shouldBroadcastAvailability*(ctx: DownloadContext): bool =
  ctx.availabilityTracker.shouldBroadcast(ctx.scheduler.completedWatermark())

proc getAvailabilityBroadcast*(
    ctx: DownloadContext
): seq[tuple[start: uint64, count: uint64]] =
  ctx.availabilityTracker.getRanges(ctx.scheduler.completedWatermark())

proc markAvailabilityBroadcasted*(ctx: DownloadContext) =
  ctx.availabilityTracker.markBroadcasted(ctx.scheduler.completedWatermark())

proc batchBytes*(ctx: DownloadContext): uint64 =
  ctx.scheduler.batchSizeCount.uint64 * ctx.blockSize.uint64

proc batchTimeout*(
    ctx: DownloadContext, peer: PeerContext, batchCount: uint64
): Duration =
  peer.batchTimeout(batchCount * ctx.blockSize.uint64)

proc progress*(ctx: DownloadContext): DownloadProgress =
  DownloadProgress(
    blocksCompleted: ctx.received,
    totalBlocks: ctx.totalBlocks,
    bytesTransferred: ctx.bytesReceived,
  )

proc markBlockInFlight(ctx: DownloadContext, index: uint64, peerId: PeerId) =
  ctx.inFlightBlocks[index] = peerId

proc isBlockInFlight(ctx: DownloadContext, index: uint64): bool =
  index in ctx.inFlightBlocks

proc inFlightCount(ctx: DownloadContext): int =
  ctx.inFlightBlocks.len

proc remainingBlocks(ctx: DownloadContext): uint64 =
  if ctx.totalBlocks > ctx.received:
    ctx.totalBlocks - ctx.received
  else:
    0
