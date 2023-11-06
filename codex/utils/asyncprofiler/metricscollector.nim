import std/algorithm
import std/enumerate
import std/sequtils
import std/times

import asyncprofiler
import metrics

when defined(metrics):
  type
    AsyncProfilerInfo* = ref object of Gauge
      perfSampler: PerfSampler
      k: int

    PerfSampler = proc (): MetricsSummary {.raises: [].}

    ProfilerMetric = (SrcLoc, OverallMetrics)

  proc newCollector*(
    AsyncProfilerInfo: typedesc,
    name: string,
    help: string,
    perfSampler: PerfSampler,
    k: int = 10,
    registry: Registry = defaultRegistry,
  ): AsyncProfilerInfo =
    result = AsyncProfilerInfo.newCollector(
      name = name, help = help, registry = registry)
    result.perfSampler = perfSampler
    result.k = k

  proc metricValue(duration: timer.Duration):
    float64 = duration.nanoseconds.float64

  proc collectSlowestProcs(
    self: AsyncProfilerInfo,
    profilerMetrics: seq[ProfilerMetric],
    prometheusMetrics: var Metrics,
    timestampMillis: int64,
    k: int,
  ): void =

    const locationLabelsKeys = @["proc", "file", "line"]

    for (i, pair) in enumerate(profilerMetrics):
      if i == k:
        break

      let (location, metrics) = pair

      proc addLabeledMetric(name: string,
        value: timer.Duration,
        prometheusMetrics: var Metrics): void =
        let labelValues = @[
          $(location.procedure),
          $(location.file),
          $(location.line),
        ]

        var procMetrics = prometheusMetrics.mGetOrPut(labelValues, @[])

        procMetrics.add(
          Metric(
            name: name,
            value: value.metricValue(),
            labels: locationLabelsKeys,
            labelValues: labelValues,
          )
        )

        # If you don't reassign, your modifications are simply lost due to nim's
        # weird var semantics.
        prometheusMetrics[labelValues] = procMetrics

      addLabeledMetric(
        "total_exec_time", metrics.totalExecTime, prometheusMetrics)
      addLabeledMetric(
        "total_run_time", metrics.totalRunTime, prometheusMetrics)
      addLabeledMetric(
        "total_wall_time", metrics.totalWallTime, prometheusMetrics)
      addLabeledMetric(
        "max_single_exec_time", metrics.maxSingleTime, prometheusMetrics)

  proc collectOutlierMetrics(
    self: AsyncProfilerInfo,
    profilerMetrics: seq[ProfilerMetric],
    prometheusMetrics: var Metrics,
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

    prometheusMetrics[@[]].add(Metric(
      name: "largest_total_exec_time",
      value: largestExecTime.metricValue(),
      timestamp: timestampMillis,
    ))

    prometheusMetrics[@[]].add(Metric(
      name: "largest_max_exec_time",
      value: largestMaxExecTime.metricValue(),
      timestamp: timestampMillis,
    ))

  method collect*(self: AsyncProfilerInfo): Metrics =
    let now = times.getTime().toMilliseconds()

    var prometheusMetrics = Metrics()
    prometheusMetrics[@[]] = newSeq[Metric]()

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

    # otherwise the compiler keeps complaining of a phantom KeyError
    {.cast(raises:[]).}:
      self.collectOutlierMetrics(currentMetrics, prometheusMetrics, now)
      self.collectSlowestProcs(currentMetrics, prometheusMetrics, now, self.k)

    prometheusMetrics

  var asyncProfilerInfo* {.global.} = AsyncProfilerInfo.newCollector(
    "async_profiler_info", "Async profiler info",
    perfSampler = getFutureSummaryMetrics
  )
