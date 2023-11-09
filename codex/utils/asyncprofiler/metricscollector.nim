import std/algorithm
import std/enumerate
import std/sequtils
import std/times

import asyncprofiler
import metrics

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

    PerfSampler = proc (): MetricsSummary {.raises: [].}

    Clock = proc (): Time {.raises: [].}

    ProfilerMetric = (SrcLoc, OverallMetrics)

  const locationLabels = ["proc", "file", "line"]

  # Per-proc Metrics
  declarePublicGauge(
    chronos_exec_time_total,
    "total time in which this proc actively occupied the event loop thread",
    labels = locationLabels,
  )

  declarePublicGauge(
    chronos_run_time_total,
    "chronos_exec_time_total of this proc plus of all its children (procs" &
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

  # Global Statistics
  declarePublicGauge(
    chronos_largest_exec_time_total,
    "the largest chronos_exec_time_total of all procs",
  )

  declarePublicGauge(
    chronos_largest_exec_time_max,
    "the largest chronos_single_exec_time_max of all procs",
  )

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

      chronos_exec_time_total.set(metrics.totalExecTime.nanoseconds,
        labelValues = locationLabels)

      chronos_run_time_total.set(metrics.totalRunTime.nanoseconds,
        labelValues = locationLabels)

      chronos_wall_time_total.set(metrics.totalWallTime.nanoseconds,
        labelValues = locationLabels)

      chronos_single_exec_time_max.set(metrics.maxSingleTime.nanoseconds,
        labelValues = locationLabels)

      chronos_call_count_total.set(metrics.count, labelValues = locationLabels)

  proc collectOutlierMetrics(
    self: AsyncProfilerInfo,
    profilerMetrics: seq[ProfilerMetric],
    timestampMillis: int64,
  ): void =
    ## Adds summary metrics for the procs that have the highest exec time
    ## (which stops the async loop) and the highest max exec time. This can
    ## help spot outliers.

    var largestExecTime = low(timer.Duration)
    var largestMaxExecTime = low(timer.Duration)

    for (_, metric) in profilerMetrics:
      if metric.maxSingleTime > largestMaxExecTime:
        largestMaxExecTime = metric.maxSingleTime
      if metric.totalExecTime > largestExecTime:
        largestExecTime = metric.totalExecTime

    chronos_largest_exec_time_total.set(largestExecTime.nanoseconds)
    chronos_largest_exec_time_max.set(largestMaxExecTime.nanoseconds)

  proc collect*(self: AsyncProfilerInfo, force: bool = false): void =
    let now = self.clock()

    if not force and (now - self.lastSample < self.sampleInterval):
      return

    self.collections += 1

    var currentMetrics = self.
      perfSampler().
      pairs.
      toSeq.
      map(
        proc (pair: (ptr SrcLoc, OverallMetrics)): ProfilerMetric =
          (pair[0][], pair[1])
      ).
      sorted(
        proc (a, b: ProfilerMetric): int =
          cmp(a[1].totalExecTime, b[1].totalExecTime),
        order = SortOrder.Descending
      )

    self.collectOutlierMetrics(currentMetrics, now.toMilliseconds())
    self.collectSlowestProcs(currentMetrics, now.toMilliseconds(), self.k)

    self.lastSample = now

  proc resetMetric(gauge: Gauge): void =
    # We try to be as conservative as possible and not write directly to
    # internal state. We do need to read from it, though.
    for labelValues in gauge.metrics.keys:
      gauge.set(0.int64, labelValues = labelValues)

  proc reset*(self: AsyncProfilerInfo): void =
    resetMetric(chronos_exec_time_total)
    resetMetric(chronos_run_time_total)
    resetMetric(chronos_wall_time_total)
    resetMetric(chronos_call_count_total)
    resetMetric(chronos_single_exec_time_max)
    resetMetric(chronos_largest_exec_time_total)
    resetMetric(chronos_largest_exec_time_max)

  var asyncProfilerInfo* {.global.}: AsyncProfilerInfo

  proc initDefault*(AsyncProfilerInfo: typedesc, k: int) =
    asyncProfilerInfo = AsyncProfilerInfo.newCollector(
      perfSampler = getFutureSummaryMetrics,
      k = k,
      # We want to collect metrics every 5 seconds.
      sampleInterval = initDuration(seconds = 5),
      clock = proc (): Time = getTime(),
    )

    setChangeCallback(proc (): void = asyncProfilerInfo.collect())
