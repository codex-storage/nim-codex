import std/sequtils
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

  let fooMetric = OverallMetrics(
    totalExecTime: 2.seconds,
    totalRunTime: 2.seconds,
    totalWallTime: 2.seconds,
    minSingleTime: 100.nanoseconds,
    maxSingleTime: 1500.milliseconds,
    count: 10
  )

  test "should serialize OverallMetrics":
    check %fooMetric == %*{
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
      (addr fooLoc): fooMetric
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

  test "should sort MetricsSummary by the required key":
    var barLoc = SrcLoc(
      procedure: "bar",
      file: "bar.nim",
      line: 1
    )

    var barMetrics = OverallMetrics(
      totalExecTime: 3.seconds,
      totalRunTime: 1.seconds,
      totalWallTime: 1.seconds,
      minSingleTime: 100.nanoseconds,
      maxSingleTime: 1500.milliseconds,
      count: 5
    )

    var summary: MetricsSummary = {
      (addr fooLoc): fooMetric,
      (addr barLoc): barMetrics
    }.toTable

    check (%summary).sortBy("totalExecTime").getElems.map(
      proc (x: JsonNode): string = x["location"]["procedure"].getStr) == @["bar", "foo"]

    check (%summary).sortBy("count").getElems.map(
      proc (x: JsonNode): string = x["location"]["procedure"].getStr) == @["foo", "bar"]
