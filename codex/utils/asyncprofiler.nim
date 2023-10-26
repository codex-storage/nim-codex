
import std/[tables, macros, options, hashes]
import pkg/chronos
import pkg/chronos/timer


type
  FutureMetric = object
    ## Holds average timing information for a given closure
    closureLoc*: ptr SrcLoc
    created*: Moment
    start*: Option[Moment]
    duration*: Duration
    blocks*: int
    initDuration*: Duration
    durationChildren*: Duration

  CallbackMetric = object
    totalExecTime*: Duration
    totalWallTime*: Duration
    totalRunTime*: Duration
    minSingleTime*: Duration
    maxSingleTime*: Duration
    count*: int64

var
  futureDurations: Table[uint, FutureMetric]
  callbackDurations: Table[ptr SrcLoc, CallbackMetric]

proc setFutureCreate(fut: FutureBase) {.raises: [].} =
  ## used for setting the duration
  let loc = fut.internalLocation[Create]
  futureDurations[fut.id] = FutureMetric()
  futureDurations.withValue(fut.id, metric):
    metric.created = Moment.now()
    echo loc, "; future create "

proc setFutureStart(fut: FutureBase) {.raises: [].} =
  ## used for setting the duration
  let loc = fut.internalLocation[Create]
  assert futureDurations.hasKey(fut.id)
  futureDurations.withValue(fut.id, metric):
    let ts = Moment.now()
    metric.start = some ts
    metric.blocks.inc()
    echo loc, "; future start: ", metric.initDuration

proc setFuturePause(fut, child: FutureBase) {.raises: [].} =
  ## used for setting the duration
  let loc = fut.internalLocation[Create]
  let childLoc = if child.isNil: nil else: child.internalLocation[Create]
  var durationChildren = ZeroDuration
  var initDurationChildren = ZeroDuration
  if childLoc != nil:
    futureDurations.withValue(child.id, metric):
      durationChildren = metric.duration
      initDurationChildren = metric.initDuration
  assert futureDurations.hasKey(fut.id)
  futureDurations.withValue(fut.id, metric):
    if metric.start.isSome:
      let ts = Moment.now()
      metric.duration += ts - metric.start.get()
      metric.duration -= initDurationChildren
      if metric.blocks == 1:
        metric.initDuration = ts - metric.created # tricky,
          # the first block of a child iterator also
          # runs on the parents clock, so we track our first block
          # time so any parents can get it
      echo loc, "; child firstBlock time: ", initDurationChildren

      metric.durationChildren += durationChildren
      metric.start = none Moment
    echo loc, "; future pause ", if childLoc.isNil: "" else: " child: " & $childLoc

proc setFutureDuration(fut: FutureBase) {.raises: [].} =
  ## used for setting the duration
  let loc = fut.internalLocation[Create]
  # assert  "set duration: " & $loc
  var fm: FutureMetric
  # assert futureDurations.pop(fut.id, fm)
  futureDurations.withValue(fut.id, metric):
    fm = metric[]

  discard callbackDurations.hasKeyOrPut(loc, CallbackMetric(minSingleTime: InfiniteDuration))
  callbackDurations.withValue(loc, metric):
    echo loc, " set duration: ", callbackDurations.hasKey(loc)
    metric.totalExecTime += fm.duration
    metric.totalWallTime += Moment.now() - fm.created
    metric.totalRunTime += metric.totalExecTime + fm.durationChildren
    echo loc, " child duration: ", fm.durationChildren
    metric.count.inc
    metric.minSingleTime = min(metric.minSingleTime, fm.duration)
    metric.maxSingleTime = max(metric.maxSingleTime, fm.duration)
    # handle overflow
    if metric.count == metric.count.typeof.high:
      metric.totalExecTime = ZeroDuration
      metric.count = 0

onFutureCreate =
  proc (f: FutureBase) {.gcsafe.} =
    {.cast(gcsafe).}:
      f.setFutureCreate()
onFutureRunning =
  proc (f: FutureBase) {.gcsafe.} =
    {.cast(gcsafe).}:
      f.setFutureStart()
onFuturePause =
  proc (f, child: FutureBase) {.gcsafe.} =
    {.cast(gcsafe).}:
      f.setFuturePause(child)
onFutureStop =
  proc (f: FutureBase) {.gcsafe.} =
    {.cast(gcsafe).}:
      f.setFuturePause(nil)
      f.setFutureDuration()

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

      let metrics = callbackDurations
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
          check v.totalExecTime >= 150.milliseconds()
          check v.totalExecTime <= 170.milliseconds()

          check v.totalRunTime >= 200.milliseconds()
          check v.totalRunTime <= 230.milliseconds()
          discard
      echo ""
