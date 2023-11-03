## Utilities for serializing profiler metrics.

import std/json

import asyncprofiler

proc `%`*(o: Duration): JsonNode =
  %(o.nanoseconds)

proc `%`*(o: cstring): JsonNode =
  %($(o))

proc `%`*(o: MetricsSummary): JsonNode =
  var rows = newJArray()
  for (location, metric) in o.pairs:
    var row = %(metric)
    row["location"] = %(location[])
    rows.add(row)

  rows
