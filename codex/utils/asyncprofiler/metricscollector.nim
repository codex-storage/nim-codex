import std/algorithm
import std/enumerate
import std/sequtils
import std/tables
import std/times

import pkg/chronos
import pkg/chronos/profiler
import pkg/metrics

when defined(metrics):
  type
    AsyncProfilerInfo* = ref object of RootObj
      perfSampler: PerfSampler
      sampleInterval: times.Duration
      clock: Clock
      k: int
      init: bool
      lastSample: Time
      collections*: uint

    PerfSampler = proc (): MetricsTotals {.raises: [].}

    Clock = proc (): Time {.raises: [].}

    ProfilerMetric = (SrcLoc, AggregateFutureMetrics)

  const locationLabels = ["proc", "file", "line"]

  # Per-proc Metrics
  declarePublicGauge(
    chronos_exec_time_total,
    "total time in which this proc actively occupied the event loop thread",
    labels = locationLabels,
  )

  declarePublicGauge(
    chronos_exec_time_with_children_total,
    "chronos_exec_time_with_children_total of this proc plus of all its children (procs" &
    "that this proc called and awaited for)",
    labels = locationLabels,
  )

  declarePublicGauge(
    chronos_wall_time_total,
    "the amount of time elapsed from when the async proc was started to when" &
    "it completed",
    labels = locationLabels,
  )

  declarePublicGauge(
    chronos_call_count_total,
    "the total number of times this async proc was called and completed",
    labels = locationLabels,
  )

  # Per-proc Statistics
  declarePublicGauge(
    chronos_single_exec_time_max,
    "the maximum execution time for a single call of this proc",
    labels = locationLabels,
  )

  # Keeps track of the thread initializing the module. This is the only thread
  # that will be allowed to interact with the metrics collector.
  let moduleInitThread = getThreadId()

  proc newCollector*(
    AsyncProfilerInfo: typedesc,
    perfSampler: PerfSampler,
    clock: Clock,
    sampleInterval: times.Duration,
    k: int = 10,
  ): AsyncProfilerInfo = AsyncProfilerInfo(
    perfSampler: perfSampler,
    clock: clock,
    k: k,
    sampleInterval: sampleInterval,
    init: true,
    lastSample: low(Time),
  )

  proc collectSlowestProcs(
    self: AsyncProfilerInfo,
    profilerMetrics: seq[ProfilerMetric],
    timestampMillis: int64,
    k: int,
  ): void =

    for (i, pair) in enumerate(profilerMetrics):
      if i == k:
        break

      let (location, metrics) = pair

      let locationLabels = @[
        $(location.procedure),
        $(location.file),
        $(location.line),
      ]

      chronos_exec_time_total.set(metrics.execTime.nanoseconds,
        labelValues = locationLabels)

      chronos_exec_time_with_children_total.set(
        metrics.execTimeWithChildren.nanoseconds,
        labelValues = locationLabels
      )

      chronos_wall_time_total.set(metrics.wallClockTime.nanoseconds,
        labelValues = locationLabels)

      chronos_single_exec_time_max.set(metrics.execTimeMax.nanoseconds,
        labelValues = locationLabels)

      chronos_call_count_total.set(metrics.callCount.int64,
        labelValues = locationLabels)

  proc collect*(self: AsyncProfilerInfo, force: bool = false): void =
    # Calling this method from the wrong thread has happened a lot in the past,
    # so this makes sure we're not doing anything funny.
    assert getThreadId() == moduleInitThread, "You cannot call collect() from" &
      " a thread other than the one that initialized the metricscolletor module"

    let now = self.clock()
    if not force and (now - self.lastSample < self.sampleInterval):
      return

    self.collections += 1
    var currentMetrics = self.
      perfSampler().
      pairs.
      toSeq.
      # We don't scoop metrics with 0 exec time as we have a limited number of
      # prometheus slots, and those are less likely to be useful in debugging
      # Chronos performance issues.
      filter(
        proc (pair: ProfilerMetric): bool =
          pair[1].execTimeWithChildren.nanoseconds > 0
      ).
      sorted(
        proc (a, b: ProfilerMetric): int =
          cmp(a[1].execTimeWithChildren, b[1].execTimeWithChildren),
        order = SortOrder.Descending
      )

    self.collectSlowestProcs(currentMetrics, now.toMilliseconds(), self.k)

    self.lastSample = now

  proc resetMetric(gauge: Gauge): void =
    # We try to be as conservative as possible and not write directly to
    # internal state. We do need to read from it, though.
    for labelValues in gauge.metrics.keys:
      gauge.set(0.int64, labelValues = labelValues)

  proc reset*(self: AsyncProfilerInfo): void =
    resetMetric(chronos_exec_time_total)
    resetMetric(chronos_exec_time_with_children_total)
    resetMetric(chronos_wall_time_total)
    resetMetric(chronos_call_count_total)
    resetMetric(chronos_single_exec_time_max)

  var asyncProfilerInfo* {.global.}: AsyncProfilerInfo
  var wrappedEventHandler {.global.}: proc (e: Event) {.nimcall, gcsafe, raises: [].}

  proc initDefault*(AsyncProfilerInfo: typedesc, k: int) =
    assert getThreadId() == moduleInitThread, "You cannot call " &
      "initDefault() from a thread other than the one that initialized the " &
      "metricscolletor module."

    asyncProfilerInfo = AsyncProfilerInfo.newCollector(
      perfSampler = proc (): MetricsTotals = getMetrics().totals,
      k = k,
      # We want to collect metrics every 5 seconds.
      sampleInterval = initDuration(seconds = 5),
      clock = proc (): Time = getTime(),
    )

    wrappedEventHandler = handleFutureEvent
    handleFutureEvent = proc (e: Event) {.nimcall, gcsafe.} =
      {.cast(gcsafe).}:
        wrappedEventHandler(e)

        if e.newState == ExtendedFutureState.Completed:
          asyncProfilerInfo.collect()

