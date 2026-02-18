## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[deques, options, math]
import pkg/chronos

const
  RttSampleCount* = 8
  MinRequestsPerPeer* = 2
  MaxRequestsPerPeer* = 4
  DefaultRequestsPerPeer* = 2
  DefaultPipelineDepth* = 2
  MinThroughputDuration* = 100.milliseconds

type PeerPerfStats* = object
  rttSamples: Deque[uint64]
  totalBytes: uint64
  firstByteTime: Option[Moment]
  lastByteTime: Option[Moment]

proc new*(T: type PeerPerfStats): PeerPerfStats =
  PeerPerfStats(
    rttSamples: initDeque[uint64](RttSampleCount),
    totalBytes: 0,
    firstByteTime: none(Moment),
    lastByteTime: none(Moment),
  )

proc recordRequest*(self: var PeerPerfStats, rttMicros: uint64, bytes: uint64) =
  if self.rttSamples.len >= RttSampleCount:
    discard self.rttSamples.popFirst()
  self.rttSamples.addLast(rttMicros)

  let now = Moment.now()
  if self.firstByteTime.isNone:
    self.firstByteTime = some(now)
  self.lastByteTime = some(now)
  self.totalBytes += bytes

proc avgRttMicros*(self: PeerPerfStats): Option[uint64] =
  if self.rttSamples.len == 0:
    return none(uint64)

  var total: uint64 = 0
  for sample in self.rttSamples:
    total += sample

  some(total div self.rttSamples.len.uint64)

proc throughputBps*(self: PeerPerfStats): Option[uint64] =
  if self.firstByteTime.isNone or self.lastByteTime.isNone:
    return none(uint64)

  let
    first = self.firstByteTime.get()
    last = self.lastByteTime.get()
    duration = last - first

  if duration < MinThroughputDuration:
    return none(uint64)

  let secs = duration.nanoseconds.float64 / 1_000_000_000.0
  some((self.totalBytes.float64 / secs).uint64)

proc optimalPipelineDepth*(self: PeerPerfStats, batchBytes: uint64): int =
  if batchBytes == 0:
    return DefaultPipelineDepth

  let rttMicrosOpt = self.avgRttMicros()
  if rttMicrosOpt.isNone:
    return DefaultRequestsPerPeer

  let throughputOpt = self.throughputBps()
  if throughputOpt.isNone:
    return DefaultRequestsPerPeer

  let
    rttMicros = rttMicrosOpt.get()
    throughput = throughputOpt.get()
    rttSecs = rttMicros.float64 / 1_000_000.0
    bdpBytes = throughput.float64 * rttSecs
    optimalRequests = ceil(bdpBytes / batchBytes.float64).int
  return clamp(optimalRequests, MinRequestsPerPeer, MaxRequestsPerPeer)

proc totalBytes*(self: PeerPerfStats): uint64 =
  self.totalBytes

proc sampleCount*(self: PeerPerfStats): int =
  self.rttSamples.len

proc reset*(self: var PeerPerfStats) =
  self.rttSamples.clear()
  self.totalBytes = 0
  self.firstByteTime = none(Moment)
  self.lastByteTime = none(Moment)
