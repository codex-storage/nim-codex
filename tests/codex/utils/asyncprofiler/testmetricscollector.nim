import std/times
import std/unittest

import pkg/chronos/profiler
import pkg/metrics

import codex/utils/asyncprofiler/metricscollector

suite "asyncprofiler metrics collector":

  var locations = @[
    SrcLoc(procedure: "start", file: "discovery.nim", line: 174),
    SrcLoc(procedure: "start", file: "discovery.nim", line: 192),
    SrcLoc(procedure: "query", file: "manager.nim", line: 323),
    SrcLoc(procedure: "update", file: "sqliteds.nim", line: 107),
    SrcLoc(procedure: "idle", file: "idle.nim", line: 100),
  ]

  let sample = {
    locations[0]: AggregateFutureMetrics(
      execTime: timer.nanoseconds(90062),
      execTimeMax: timer.nanoseconds(80062),
      childrenExecTime: timer.nanoseconds(52044),
      wallClockTime: timer.nanoseconds(174567),
      callCount: 1
    ),
    locations[1]: AggregateFutureMetrics(
      execTime: timer.nanoseconds(91660),
      execTimeMax: timer.nanoseconds(81660),
      childrenExecTime: timer.nanoseconds(52495),
      wallClockTime: timer.nanoseconds(72941),
      callCount: 1
    ),
    locations[2]: AggregateFutureMetrics(
      execTime: timer.nanoseconds(60529),
      execTimeMax: timer.nanoseconds(60529),
      childrenExecTime: timer.nanoseconds(9689),
      wallClockTime: timer.nanoseconds(60784),
      callCount: 1
    ),
    locations[3]: AggregateFutureMetrics(
      execTime: timer.nanoseconds(60645),
      execTimeMax: timer.nanoseconds(41257),
      childrenExecTime: timer.nanoseconds(72934),
      wallClockTime: timer.nanoseconds(60813),
      callCount: 3
    ),
    locations[4]: AggregateFutureMetrics(
      execTime: timer.nanoseconds(0),
      execTimeMax: timer.nanoseconds(0),
      childrenExecTime: timer.nanoseconds(0),
      wallClockTime: timer.nanoseconds(60813),
      callCount: 3
    )
  }.toTable

  var wallTime = getTime()

  var collector: AsyncProfilerInfo

  proc setupCollector(k: int = high(int)): void =
    collector = AsyncProfilerInfo.newCollector(
      perfSampler = proc (): MetricsTotals = sample,
      clock = proc (): Time = wallTime,
      sampleInterval = times.initDuration(minutes = 5),
      k = k,
    )

    collector.reset()
    collector.collect()

  test "should create labeled series for the k slowest procs in terms of execTime":
    setupCollector(k = 3)

    check chronos_exec_time_with_children_total.value(
      labelValues = @["start", "discovery.nim", "192"]) == 144155
    check chronos_exec_time_with_children_total.value(
      labelValues = @["start", "discovery.nim", "174"]) == 142106
    check chronos_exec_time_with_children_total.value(
      labelValues = @["update", "sqliteds.nim", "107"]) == 133579

    # This is out of the top-k slowest, so should not have been recorded.
    expect system.KeyError:
      discard chronos_exec_time_with_children_total.value(
        labelValues = @["query", "manager.nim", "323"])

  test "should not collect metrics again unless enough time has elapsed from last collection":
    setupCollector()

    check collector.collections == 1
    collector.collect()
    check collector.collections == 1

    wallTime += 6.minutes

    collector.collect()
    check collector.collections == 2

  test "should not collect metrics for futures with zero total exec time":
    setupCollector()

    expect system.KeyError:
      discard chronos_exec_time_total.value(
        labelValues = @["idle", "idle.nim", "100"])
