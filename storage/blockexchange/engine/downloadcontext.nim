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
  DefaultBatchTimeoutUnknownBlockSize* = 30.seconds # timeout for unknown block size

static:
  const
    worstCaseRanges = MaxPresenceWindowBlocks div 2
    worstCasePresenceBytes = worstCaseRanges * 16 + 1024 # +1KB safe overhead
  doAssert worstCasePresenceBytes < MaxMessageSize,
    "Presence window too large for MaxMessageSize with minimum block size. " &
      "Worst case: " & $worstCasePresenceBytes & " bytes, limit: " & $MaxMessageSize &
      " bytes"

type
  DownloadProgress = object
    blocksCompleted*: uint64
    totalBlocks*: uint64
    bytesTransferred*: uint64

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
    presenceWindowStart*: uint64
    presenceWindowEnd*: uint64 # exclusive
    presenceWindowSize*: uint64 # in blocks
    lastAvailabilityBroadcastTime*: Moment
    lastAvailabilityBroadcastedWatermark*: uint64
    presenceBroadcastInterval*: Duration

proc computePresenceWindowSize*(blockSize: uint32): uint64 =
  result = PresenceWindowBytes div blockSize.uint64
  if result == 0:
    result = 1

proc randomBroadcastInterval(): Duration =
  # try avoid thundering herd.

  rand(
    PresenceBroadcastIntervalMin.milliseconds.int ..
      PresenceBroadcastIntervalMax.milliseconds.int
  ).milliseconds

proc new*(
    T: type DownloadContext,
    treeCid: Cid,
    blockSize: uint32,
    totalBlocks: uint64,
    alreadyHave: uint64 = 0,
): DownloadContext =
  let windowSize =
    if blockSize > 0:
      computePresenceWindowSize(blockSize)
    else:
      PresenceWindowBlocks
  let initialWindowEnd = min(windowSize, totalBlocks)

  DownloadContext(
    treeCid: treeCid,
    blockSize: blockSize,
    totalBlocks: totalBlocks,
    received: alreadyHave,
    blocksReturned: 0,
    bytesReceived: 0,
    scheduler: Scheduler.new(),
    swarm: Swarm.new(),
    inFlightBlocks: initTable[uint64, PeerId](),
    presenceWindowStart: 0,
    presenceWindowEnd: initialWindowEnd,
    presenceWindowSize: windowSize,
    lastAvailabilityBroadcastTime: Moment.now(),
    lastAvailabilityBroadcastedWatermark: 0,
    presenceBroadcastInterval: randomBroadcastInterval(),
  )

proc isComplete*(ctx: DownloadContext): bool =
  ctx.blocksReturned >= ctx.totalBlocks or ctx.received >= ctx.totalBlocks

proc hasBlockSize*(ctx: DownloadContext): bool =
  ctx.blockSize > 0

proc setBlockSize*(ctx: DownloadContext, blockSize: uint32) =
  if ctx.blockSize == 0 and blockSize > 0:
    ctx.blockSize = blockSize
    ctx.scheduler.updateBatchSize(computeBatchSize(blockSize).uint64)

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

proc currentPresenceWindow*(ctx: DownloadContext): tuple[start: uint64, count: uint64] =
  (
    start: ctx.presenceWindowStart,
    count: ctx.presenceWindowEnd - ctx.presenceWindowStart,
  )

proc needsNextPresenceWindow*(ctx: DownloadContext): bool =
  if ctx.presenceWindowEnd >= ctx.totalBlocks:
    return false

  let
    watermark = ctx.scheduler.completedWatermark()
    windowSize = ctx.presenceWindowEnd - ctx.presenceWindowStart
    threshold =
      ctx.presenceWindowStart + (windowSize.float * PresenceWindowThreshold).uint64

  watermark >= threshold

proc advancePresenceWindow*(ctx: DownloadContext): tuple[start: uint64, count: uint64] =
  let
    newStart = ctx.presenceWindowEnd
    newEnd = min(newStart + ctx.presenceWindowSize, ctx.totalBlocks)

  ctx.presenceWindowStart = newStart
  ctx.presenceWindowEnd = newEnd

  let count = newEnd - newStart
  (start: newStart, count: count)

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
  let watermark = ctx.scheduler.completedWatermark()
  let newBlocks = watermark - ctx.lastAvailabilityBroadcastedWatermark
  if newBlocks == 0:
    return false

  let timeSinceLast = Moment.now() - ctx.lastAvailabilityBroadcastTime
  newBlocks >= PresenceBroadcastBlockThreshold or
    timeSinceLast >= ctx.presenceBroadcastInterval

proc getAvailabilityBroadcast*(
    ctx: DownloadContext
): tuple[start: uint64, count: uint64] =
  let watermark = ctx.scheduler.completedWatermark()
  (
    start: ctx.lastAvailabilityBroadcastedWatermark,
    count: watermark - ctx.lastAvailabilityBroadcastedWatermark,
  )

proc markAvailabilityBroadcasted*(ctx: DownloadContext) =
  ctx.lastAvailabilityBroadcastTime = Moment.now()
  ctx.lastAvailabilityBroadcastedWatermark = ctx.scheduler.completedWatermark()
  ctx.presenceBroadcastInterval = randomBroadcastInterval()

proc batchBytes*(ctx: DownloadContext): uint64 =
  ctx.scheduler.batchSizeCount.uint64 * ctx.blockSize.uint64

proc batchTimeout*(
    ctx: DownloadContext, peer: PeerContext, batchCount: uint64
): Duration =
  let bytes = batchCount * ctx.blockSize.uint64
  if bytes > 0:
    peer.batchTimeout(bytes)
  else:
    DefaultBatchTimeoutUnknownBlockSize

## private - only used in tests
proc progress(ctx: DownloadContext): DownloadProgress =
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

proc presenceWindowContains(ctx: DownloadContext, blockIndex: uint64): bool =
  blockIndex >= ctx.presenceWindowStart and blockIndex < ctx.presenceWindowEnd
