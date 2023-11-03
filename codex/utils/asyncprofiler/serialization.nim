## Utilities for serializing profiler metrics.
import std/algorithm
import std/json

import asyncprofiler

proc `%`*(o: Duration): JsonNode =
  %(o.nanoseconds)

proc `%`*(o: cstring): JsonNode =
  %($(o))

proc toJson*(o: MetricsSummary): JsonNode =
  var rows = newJArray()
  for (location, metric) in o.pairs:
    var row = %(metric)
    row["location"] = %(location[])
    rows.add(row)

  rows

proc `%`*(o: MetricsSummary): JsonNode = o.toJson()

proc sortBy*(jArray: JsonNode, metric: string): JsonNode {.raises: [ref KeyError].} =
  %(jArray.getElems.sorted(
    proc (a, b: JsonNode): int {.raises: [ref KeyError].} =
      cmp(a[metric].getInt, b[metric].getInt),
    order=SortOrder.Descending))
