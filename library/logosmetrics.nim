import std/[json, locks, times, sets]

import pkg/metrics

proc toJson(collector: Collector, metrics: var seq[JsonNode] = @[]) =
  # We know the closure won't outlive `metrics` so this is
  # an acceptable hack.
  let metricsPtr = addr metrics

  proc serializeMetric(
      name: string,
      value: float64,
      labels: openArray[string] = [],
      labelValues: openArray[string] = [],
      timestamp: Time,
  ) {.raises: [].} =
    # The logos openmetrics format (https://github.com/logos-co/openmetrics-module)
    # does not include the timestamp, so we don't include it either.
    var labelMap = newJObject()
    for i in 0 ..< labels.len:
      labelMap[labels[i]] = %labelValues[i]

    metricsPtr[].add(%*{"name": name, "value": value, "labels": labelMap})

  collector.collect(serializeMetric)

# Serializes all collectors in a given registry to a Logos openmetrics-compatible
# format. Allows including only specific collectors by name.
proc toJson*(registry: Registry, includeOnly: openArray[string] = []): JsonNode =
  var metrics = newSeq[JsonNode]()
  withLock registry.lock:
    for collector in registry.collectors:
      if includeOnly.len > 0:
        if collector.name notin includeOnly:
          continue
      collector.toJson(metrics)

  result = %*{"metrics": metrics}
