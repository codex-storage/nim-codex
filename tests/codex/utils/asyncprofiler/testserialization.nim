import std/sequtils
import std/tables
import std/unittest
import std/json

import chronos/profiler

import codex/utils/asyncprofiler/serialization

import ../../helpers

checksuite "asyncprofiler metrics serializer":

  let fooLoc = SrcLoc(
    procedure: "foo",
    file: "foo.nim",
    line: 1
  )

  let fooMetric = AggregateFutureMetrics(
    execTime: 2.seconds,
    wallClockTime: 2.seconds,
    childrenExecTime: 10.seconds,
    execTimeMax: 1500.milliseconds,
    zombieEventCount: 0,
    stillbornCount: 0,
    callCount: 10
  )

  test "should serialize AggregateFutureMetrics":
    check %fooMetric == %*{
      "execTime": 2000000000,
      "wallClockTime": 2000000000,
      "childrenExecTime": 10000000000,
      "execTimeMax": 1500000000,
      "zombieEventCount": 0,
      "stillbornCount": 0,
      "callCount": 10
    }

  test "should serialize SrcLoc":
    check %fooLoc == %*{
      "procedure": "foo",
      "file": "foo.nim",
      "line": 1
    }

  test "should serialize MetricsTotals":
    var summary: MetricsTotals = {
      fooLoc: fooMetric
    }.toTable

    check %summary == %*[%*{
      "location": %*{
        "procedure": "foo",
        "file": "foo.nim",
        "line": 1,
      },
      "execTime": 2000000000,
      "wallClockTime": 2000000000,
      "childrenExecTime": 10000000000,
      "execTimeMax": 1500000000,
      "zombieEventCount": 0,
      "stillbornCount": 0,
      "callCount": 10
    }]

  test "should sort MetricsSummary by the required key":
    let barLoc = SrcLoc(
      procedure: "bar",
      file: "bar.nim",
      line: 1
    )

    var barMetrics = AggregateFutureMetrics(
      execTime: 3.seconds,
      wallClockTime: 1.seconds,
      execTimeMax: 1500.milliseconds,
      childrenExecTime: 1.seconds,
      zombieEventCount: 0,
      stillbornCount: 0,
      callCount: 5
    )

    var summary: Table[SrcLoc, AggregateFutureMetrics] = {
      fooLoc: fooMetric,
      barLoc: barMetrics
    }.toTable

    check (%summary).sortBy("execTime").getElems.map(
      proc (x: JsonNode): string = x["location"]["procedure"].getStr) == @["bar", "foo"]

    check (%summary).sortBy("callCount").getElems.map(
      proc (x: JsonNode): string = x["location"]["procedure"].getStr) == @["foo", "bar"]
