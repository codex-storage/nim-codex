import std/times

import asyncprofiler
import metrics

when defined(metrics):
  type
    ProfilingCollector* = ref object of Gauge
      perfSampler: PerfSampler

    PerfSampler = proc (): MetricsSummary {.raises: [].}

  proc newCollector*(
    ProfilingCollector: typedesc,
    name: string,
    help: string,
    perfSampler: PerfSampler,
    registry: Registry = defaultRegistry,
  ): ProfilingCollector =
    result = ProfilingCollector.newCollector(
      name=name, help=help, registry=registry)
    result.perfSampler = perfSampler


  method collect*(self: ProfilingCollector): Metrics =
    let now = times.getTime().toMilliseconds()

    var largestExecTime = low(timer.Duration)
    var largestMaxExecTime = low(timer.Duration)
    for (locationPtr, metric) in self.perfSampler().pairs:
      if metric.maxSingleTime > largestMaxExecTime:
        largestMaxExecTime = metric.maxSingleTime

      if metric.totalExecTime > largestExecTime:
        largestExecTime = metric.totalExecTime

    result[newSeq[string]()] = @[
      Metric(
        name: "largest_total_exec_time",
        value: largestExecTime.nanoseconds.float64,
        timestamp: now,
      ),
      Metric(
        name: "largest_max_exec_time",
        value: largestMaxExecTime.nanoseconds.float64,
        timestamp: now,
      )
    ]

  var profilingCollector = ProfilingCollector.newCollector(
    name = "profiling",
    help = "Profiling metrics",
    perfSampler = getFutureSummaryMetrics
  )
