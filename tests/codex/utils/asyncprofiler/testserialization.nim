import std/tables
import std/unittest
import std/json

import codex/utils/asyncprofiler

import ../../helpers

checksuite "asyncprofiler utils":

  var fooLoc = SrcLoc(
    procedure: "foo",
    file: "foo.nim",
    line: 1
  )

  let metric = OverallMetrics(
    totalExecTime: 2.seconds,
    totalRunTime: 2.seconds,
    totalWallTime: 2.seconds,
    minSingleTime: 100.nanoseconds,
    maxSingleTime: 1500.milliseconds,
    count: 10
  )

  test "should serialize OverallMetrics":
    check %metric == %*{
      "totalExecTime": 2000000000,
      "totalRunTime": 2000000000,
      "totalWallTime": 2000000000,
      "minSingleTime": 100,
      "maxSingleTime": 1500000000,
      "count": 10
    }

  test "should serialize SrcLoc":
    check %fooLoc == %*{
      "procedure": "foo",
      "file": "foo.nim",
      "line": 1
    }

  test "should serialize MetricsSummary":
    var summary: MetricsSummary = {
      (addr fooLoc): metric
    }.toTable

    check %summary == %*[%*{
      "location": %*{
        "procedure": "foo",
        "file": "foo.nim",
        "line": 1,
      },
      "totalExecTime": 2000000000,
      "totalRunTime": 2000000000,
      "totalWallTime": 2000000000,
      "minSingleTime": 100,
      "maxSingleTime": 1500000000,
      "count": 10
    }]
