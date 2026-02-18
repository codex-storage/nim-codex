## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/libp2p
import pkg/chronos
import pkg/questionable

import ./peerstats

const
  ThroughputScoreBaseline* = 12_500_000.0 # 100 Mbps baseline for throughput scoring
  DefaultBatchTimeout* = 30.seconds # fallback when no BDP stats available
  TimeoutSafetyFactor* = 3.0
    # multiplier to account for variance (network jitter, congestion, GC pauses )
  MinBatchTimeout* = 5.seconds # min to avoid too aggressive timeouts
  MaxBatchTimeout* = 45.seconds # max to handle high contention scenarios

type PeerContext* = ref object of RootObj
  id*: PeerId
  stats*: PeerPerfStats

proc new*(T: type PeerContext, id: PeerId): PeerContext =
  PeerContext(id: id, stats: PeerPerfStats.new())

proc optimalPipelineDepth*(self: PeerContext, batchBytes: uint64): int =
  self.stats.optimalPipelineDepth(batchBytes)

proc batchTimeout*(self: PeerContext, batchBytes: uint64): Duration =
  ## find optimal timeout for a batch based on BDP
  ## timeout = min((batchBytes / throughput + RTT) * safetyFactor, maxTimeout)
  ## it falls back to default if no stats available.
  let
    throughputOpt = self.stats.throughputBps()
    rttOpt = self.stats.avgRttMicros()

  if throughputOpt.isNone or rttOpt.isNone:
    return DefaultBatchTimeout

  let
    throughput = throughputOpt.get()
    rttMicros = rttOpt.get()

  if throughput == 0:
    return DefaultBatchTimeout

  let
    transferTimeMicros = (batchBytes * 1_000_000) div throughput
    totalTimeMicros = transferTimeMicros + rttMicros
    timeoutMicros = (totalTimeMicros.float * TimeoutSafetyFactor).uint64
    timeout = microseconds(timeoutMicros.int64)

  if timeout < MinBatchTimeout:
    return MinBatchTimeout

  if timeout > MaxBatchTimeout:
    return MaxBatchTimeout

  return timeout

proc evalBDPScore*(
    self: PeerContext, batchBytes: uint64, currentLoad: int, penalty: float
): float =
  let
    pipelineDepth = self.optimalPipelineDepth(batchBytes)
    capacityScore =
      if currentLoad >= pipelineDepth:
        100.0
      else:
        (currentLoad.float / pipelineDepth.float) * 10.0

    throughputScore =
      if self.stats.throughputBps().isSome:
        let bps = self.stats.throughputBps().get().float
        if bps > 0:
          ThroughputScoreBaseline / bps
        else:
          50.0
      else:
        25.0 # normalization fallback

    rttScore =
      if self.stats.avgRttMicros().isSome:
        self.stats.avgRttMicros().get().float / 10000.0
      else:
        5.0 # normalization fallback

  return capacityScore + throughputScore + rttScore + penalty
