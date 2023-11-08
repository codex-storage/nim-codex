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
      totalExecTime: 90062.nanoseconds,
      totalRunTime: 113553.nanoseconds,
      totalWallTime: 174567.nanoseconds,
      minSingleTime: 80062.nanoseconds,
      maxSingleTime: 80062.nanoseconds,
      count: 1
    ),
    (addr locations[1]): OverallMetrics(
      totalExecTime: 91660.nanoseconds,
      totalRunTime: 71660.nanoseconds,
      totalWallTime: 72941.nanoseconds,
      minSingleTime: 71660.nanoseconds,
      maxSingleTime: 81660.nanoseconds,
      count: 1
    ),
    (addr locations[2]): OverallMetrics(
      totalExecTime: 60529.nanoseconds,
      totalRunTime: 60529.nanoseconds,
      totalWallTime: 60784.nanoseconds,
      minSingleTime: 60529.nanoseconds,
      maxSingleTime: 60529.nanoseconds,
      count: 1
    ),
    (addr locations[3]): OverallMetrics(
      totalExecTime: 60645.nanoseconds,
      totalRunTime: 156214.nanoseconds,
      totalWallTime: 60813.nanoseconds,
      minSingleTime: 5333.nanoseconds,
      maxSingleTime: 41257.nanoseconds,
      count: 3
    ),
  }.toTable

  var collector = AsyncProfilerInfo.newCollector(
    perfSampler = proc (): MetricsSummary = sample,
    k = 3,
  )

  setup:
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
