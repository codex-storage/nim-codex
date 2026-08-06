import std/[json, locks, strutils, times, sets]

import pkg/metrics

proc jsonHelp(collector: Collector): string =
  let prefix = "# HELP " & collector.name & " "
  if collector.help.startsWith(prefix):
    return collector.help[prefix.len .. ^1].strip(leading = false, trailing = true)

  return ""

proc jsonType(collector: Collector): string =
  let parts = collector.typ.splitWhitespace()
  if parts.len == 4 and parts[0] == "#" and parts[1] == "TYPE" and
      parts[2] == collector.name:
    return parts[3]

  return "unknown"

const RedundantFragments = ["logos", "storage", "_"]

func addMetricsPrefix*(name: string): string =
  ## Adds the standard Logos metrics prefix (`logos_storage_`) to a metric name.
  ## Drops repeat prefix fragments (`logos`, `storage`) before adding the prefix.
  var slice_idx: int
  while true:
    var hasFrag = false
    for fragment in RedundantFragments:
      if name.continuesWith(fragment, slice_idx):
        slice_idx += fragment.len
        hasFrag = true
        break
    if not hasFrag:
      break

  return
    if slice_idx == name.len:
      name
    else:
      # This is the only part where we should be doing copies.
      "logos_storage_" & name[slice_idx .. ^1]

proc toJson(collector: Collector, metrics: var seq[JsonNode], prefix: bool = false) =
  # We know the closure won't outlive `metrics` so this is
  # an acceptable hack.
  let metricsPtr = addr metrics
  let help = collector.jsonHelp()
  let typ = collector.jsonType()

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
    # When a label is missing, it's simply not included in the values, so we take
    # the minimum.
    for i in 0 ..< min(labelValues.len, labels.len):
      labelMap[labels[i]] = %labelValues[i]

    metricsPtr[].add(
      %*{
        "name":
          if prefix:
            addMetricsPrefix(name)
          else:
            name,
        "type": typ,
        "help": help,
        "value": value,
        "labels": labelMap,
      }
    )

  collector.collect(serializeMetric)

proc toJson*(
    registry: Registry,
    exclude: openArray[string] = [],
    includeOnly: openArray[string] = [],
    prefix: bool = false,
): JsonNode =
  ## Serializes all collectors in a given registry to a Logos openmetrics-compatible
  ## format. Allows including only specific collectors by name. Optionally, adds a
  ## standardized prefix to all metrics on output.
  ##
  ## See also:
  ##   - `addMetricsPrefix`
  ##
  var metrics = newSeq[JsonNode]()
  withLock registry.lock:
    for collector in registry.collectors:
      if exclude.len > 0:
        if collector.name in exclude:
          continue
      if includeOnly.len > 0:
        if collector.name notin includeOnly:
          continue
      collector.toJson(metrics, prefix)

  result = %*{"metrics": metrics}
