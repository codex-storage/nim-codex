import std/times
import std/unittest

import pkg/metrics

import codex/utils/asyncprofiler

import ../../helpers

suite "asyncprofiler metrics collector":

  var locations = @[
    SrcLoc(procedure: "start", file: "discovery.nim", line: 174),
    SrcLoc(procedure: "start", file: "discovery.nim", line: 192),
    SrcLoc(procedure: "query", file: "manager.nim", line: 323),
    SrcLoc(procedure: "update", file: "sqliteds.nim", line: 107),
  ]

  let sample = {
    (addr locations[0]): OverallMetrics(
      totalExecTime: timer.nanoseconds(90062),
      totalRunTime: timer.nanoseconds(113553),
      totalWallTime: timer.nanoseconds(174567),
      minSingleTime: timer.nanoseconds(80062),
      maxSingleTime: timer.nanoseconds(80062),
      count: 1
    ),
    (addr locations[1]): OverallMetrics(
      totalExecTime: timer.nanoseconds(91660),
      totalRunTime: timer.nanoseconds(71660),
      totalWallTime: timer.nanoseconds(72941),
      minSingleTime: timer.nanoseconds(71660),
      maxSingleTime: timer.nanoseconds(81660),
      count: 1
    ),
    (addr locations[2]): OverallMetrics(
      totalExecTime: timer.nanoseconds(60529),
      totalRunTime: timer.nanoseconds(60529),
      totalWallTime: timer.nanoseconds(60784),
      minSingleTime: timer.nanoseconds(60529),
      maxSingleTime: timer.nanoseconds(60529),
      count: 1
    ),
    (addr locations[3]): OverallMetrics(
      totalExecTime: timer.nanoseconds(60645),
      totalRunTime: timer.nanoseconds(156214),
      totalWallTime: timer.nanoseconds(60813),
      minSingleTime: timer.nanoseconds(5333),
      maxSingleTime: timer.nanoseconds(41257),
      count: 3
    ),
  }.toTable

  var wallTime = getTime()

  var collector: AsyncProfilerInfo

  setup:
    collector = AsyncProfilerInfo.newCollector(
      perfSampler = proc (): MetricsSummary = sample,
      clock = proc (): Time = wallTime,
      sampleInterval = times.initDuration(minutes = 5),
      k = 3,
    )

    collector.reset()
    collector.collect()

  test "should keep track of basic worst-case exec time stats":
    check chronos_largest_exec_time_total.value == 91660
    check chronos_largest_exec_time_max.value == 81660

  test "should create labeled series for the k slowest procs in terms of totalExecTime":
    check chronos_exec_time_total.value(
      labelValues = @["start", "discovery.nim", "192"]) == 91660
    check chronos_exec_time_total.value(
      labelValues = @["start", "discovery.nim", "174"]) == 90062
    check chronos_exec_time_total.value(
      labelValues = @["update", "sqliteds.nim", "107"]) == 60645

    # This is out of the top-k slowest, so should not have been recorded.
    expect system.KeyError:
      discard chronos_exec_time_total.value(
        labelValues = @["query", "manager.nim", "323"])

  test "should not collect metrics again unless enough time has elapsed from last collection":
    check collector.collections == 1
    collector.collect()
    check collector.collections == 1

    wallTime += 6.minutes

    collector.collect()
    check collector.collections == 2
