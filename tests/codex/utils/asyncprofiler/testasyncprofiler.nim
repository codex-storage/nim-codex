import pkg/asynctest
import pkg/chronos

import pkg/codex/utils/asyncprofiler

type
  FakeFuture = object
    id: uint
    internalLocation*: array[LocationKind, ptr SrcLoc]


suite "asyncprofiler":

  test "should not keep metrics for a pending future in memory after it completes":

    var fakeLoc =  SrcLoc(procedure: "foo", file: "foo.nim", line: 1)
    let future = FakeFuture(
      id: 1,
      internalLocation:  [
      LocationKind.Create: addr fakeLoc,
      LocationKind.Finish: addr fakeLoc,
    ])

    var profiler = AsyncProfiler[FakeFuture]()

    profiler.handleFutureCreate(future)
    profiler.handleFutureComplete(future)

    check len(profiler.getPerFutureMetrics()) == 0


