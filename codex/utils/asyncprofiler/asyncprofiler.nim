
import std/[tables, macros, options, hashes]
import pkg/chronos
import pkg/chronos/timer

import ../json

export tables, options, hashes, timer, chronos, SrcLoc

type
  AsyncProfiler*[TFutureBase] = object
    perFutureMetrics: PartialMetrics
    futureSummaryMetrics: MetricsSummary
    onChange: ChangeListener

  FutureMetrics* = object
    ## Tracks timing information for a single future (typically an async
    ## proc). Created when a future starts, and discarded when a future ends.
    closureLoc*: ptr SrcLoc
    created*: Moment
    start*: Option[Moment]
    duration*: Duration
    blocks*: int
    initDuration*: Duration
    durationChildren*: Duration

  OverallMetrics* = object
    ## Holds overall execution statistics for all runs of an async proc
    totalExecTime* {.serialize.}: Duration
    totalRunTime* {.serialize.}: Duration
    totalWallTime* {.serialize.}: Duration
    minSingleTime* {.serialize.}: Duration
    maxSingleTime* {.serialize.}: Duration
    count* {.serialize.}: int64

  PartialMetrics* = Table[uint, FutureMetrics]

  MetricsSummary* = Table[ptr SrcLoc, OverallMetrics]

  ChangeListener* = proc (): void {.raises: [].}

var
  profiler* {.threadvar.}: AsyncProfiler[FutureBase]
  enabled {.threadvar.}: bool

proc getPerFutureMetrics*(self: AsyncProfiler): PartialMetrics {.gcsafe.} =
  {.cast(gcsafe).}:
    self.perFutureMetrics

proc getFutureSummaryMetrics*(self: AsyncProfiler): MetricsSummary {.gcsafe.} =
  ## get a copy of the table of summary metrics for all futures.
  {.cast(gcsafe).}:
    self.futureSummaryMetrics

proc setChangeCallback*(self: var AsyncProfiler, callback: ChangeListener): void =
  ## Allows registration of a single callback which gets called whenever
  ## a the summary metric table changes.
  self.onChange = callback

proc addRun(self: var OverallMetrics, run: FutureMetrics) =
  ## Adds metrics for a single run of a given async proc to its OverallMetrics.
  self.totalExecTime += run.duration
  self.totalWallTime += Moment.now() - run.created
  self.totalRunTime += run.duration + run.durationChildren
  self.count.inc
  self.minSingleTime = min(self.minSingleTime, run.duration)
  self.maxSingleTime = max(self.maxSingleTime, run.duration)

proc handleFutureCreate*[TFutureBase](self: var AsyncProfiler[TFutureBase],
    fut: TFutureBase) {.raises: [].} =
  {.cast(gcsafe).}:
    self.perFutureMetrics[fut.id] = FutureMetrics()
    self.perFutureMetrics.withValue(fut.id, metric):
      metric.created = Moment.now()

proc handleFutureStart*[TFutureBase](self: var AsyncProfiler[TFutureBase],
    fut: TFutureBase) {.raises: [].} =
  {.cast(gcsafe).}:
    assert self.perFutureMetrics.hasKey(fut.id)
    self.perFutureMetrics.withValue(fut.id, metric):
      let ts = Moment.now()
      metric.start = some ts
      metric.blocks.inc()

proc handleFuturePause*[TFutureBase](self: var AsyncProfiler[TFutureBase],
    fut, child: TFutureBase) {.raises: [].} =
  {.cast(gcsafe).}:
    let childLoc = if child.isNil: nil else: child.internalLocation[Create]
    var durationChildren = ZeroDuration
    var initDurationChildren = ZeroDuration
    if childLoc != nil:
      self.perFutureMetrics.withValue(child.id, metric):
        durationChildren = metric.duration
        initDurationChildren = metric.initDuration

    assert self.perFutureMetrics.hasKey(fut.id)
    self.perFutureMetrics.withValue(fut.id, metric):
      if metric.start.isSome:
        let ts = Moment.now()
        metric.duration += ts - metric.start.get()
        metric.duration -= initDurationChildren
        if metric.blocks == 1:
          metric.initDuration = ts - metric.created # tricky,
            # the first block of a child iterator also
            # runs on the parents clock, so we track our first block
            # time so any parents can get it

        metric.durationChildren += durationChildren
        metric.start = none Moment

proc handleFutureComplete*[TFutureBase](self: var AsyncProfiler[TFutureBase],
    fut: TFutureBase) {.raises: [].} =
  {.cast(gcsafe).}:
    ## used for setting the duration
    let loc = fut.internalLocation[Create]
    # assert  "set duration: " & $loc
    var runMetrics: FutureMetrics
    self.perFutureMetrics.withValue(fut.id, metric):
      runMetrics = metric[]

    discard self.futureSummaryMetrics.hasKeyOrPut(loc,
      OverallMetrics(minSingleTime: InfiniteDuration))

    self.futureSummaryMetrics.withValue(loc, metric):
      metric[].addRun(runMetrics)

    self.perFutureMetrics.del(fut.id)

    if not isNil(self.onChange):
      self.onChange()

onFutureCreate =
  proc (f: FutureBase) {.nimcall, gcsafe, raises: [].} =
    if enabled:
      profiler.handleFutureCreate(f)

onFutureRunning =
  proc (f: FutureBase) {.nimcall, gcsafe, raises: [].} =
    if enabled:
      profiler.handleFutureStart(f)

onFuturePause =
  proc (f, child: FutureBase) {.nimcall, gcsafe, raises: [].} =
    if enabled:
      profiler.handleFuturePause(f, child)

onFutureStop =
  proc (f: FutureBase) {.nimcall, gcsafe, raises: [].} =
    if enabled:
      profiler.handleFuturePause(f, nil)
      profiler.handleFutureComplete(f)

proc enableChronosProfiling* (): void =
  ## This gates for which chronos event loops we want to collect metrics. This
  ## method should be called for each event loop, before chronos is started.
  enabled = true

when isMainModule:
  import std/unittest
  import std/os

  suite "async profiling":
    test "basic profiling":
      proc simpleAsyncChild() {.async.} =
        echo "child sleep..."
        os.sleep(25)

      proc simpleAsync1() {.async.} =
        for i in 0..1:
          await sleepAsync(40.milliseconds)
          await simpleAsyncChild()
          echo "sleep..."
          os.sleep(50)

      waitFor(simpleAsync1())

      let metrics = futureSummaryMetrics
      echo "\n=== metrics ==="
      echo "execTime:\ttime to execute non-async portions of async proc"
      echo "runTime:\texecution time + execution time of children"
      echo "wallTime:\twall time elapsed for future's lifetime"
      for (k,v) in metrics.pairs():
        let count = v.count
        if count > 0:
          echo ""
          echo "metric: ", $k
          echo "count: ", count
          echo "avg execTime:\t", v.totalExecTime div count, "\ttotal: ", v.totalExecTime
          echo "avg wallTime:\t", v.totalWallTime div count, "\ttotal: ", v.totalWallTime
          echo "avg runTime:\t", v.totalRunTime div count, "\ttotal: ", v.totalRunTime
        if k.procedure == "simpleAsync1":
          echo "v: ", v
          check v.totalExecTime >= 100.milliseconds()
          check v.totalExecTime <= 180.milliseconds()

          check v.totalRunTime >= 150.milliseconds()
          check v.totalRunTime <= 240.milliseconds()
          discard
      echo ""
