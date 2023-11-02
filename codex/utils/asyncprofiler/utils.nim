import asyncprofiler

import ../json


proc `%`*(o: MetricsSummary): JsonNode =
  var rows = newJArray()
  for (location, metric) in o.pairs:
    var row = %(metric)
    row["location"] = %(location[])
    rows.add(row)

  rows

proc `%`*(o: Duration): JsonNode =
  %(o.nanoseconds)

proc `%`*(o: cstring): JsonNode =
  %($(o))
