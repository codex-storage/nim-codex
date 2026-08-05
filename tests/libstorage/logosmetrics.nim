import std/json
import std/times
import std/sequtils
import std/sets

import pkg/unittest2
import pkg/metrics

import ../../library/logosmetrics

declareCounter myCounter, "Parts Counter", ["part_type"]
declareGauge myGauge, "My gauge"
declareHistogram myHistogram, "My histogram", buckets = [0.0, 1.0, 2.0]

# A badly-behaved collector that emits label/labelValue arrays of differing
# lengths.
type BadCollector = ref object of Gauge

method collect(collector: BadCollector, output: MetricHandler) =
  output(
    name = "bad_metric",
    value = 1.0,
    labels = ["label1", "label2"],
    labelValues = ["value1"],
    timestamp = Time(),
  )
  output(
    name = "bad_metric",
    value = 1.0,
    labels = ["label1", "label2"],
    labelValues = ["value1", "value2"],
    timestamp = Time(),
  )

suite "Metrics":
  test "should add prefix to unprefixed metrics":
    check "logos_storage_count" == addMetricsPrefix("count")

  test "should drop leading underscores":
    check "logos_storage_count" == addMetricsPrefix("_count")

  test "should drop repeated prefixes":
    check "logos_storage_count" == addMetricsPrefix("logos_storage_count")
    check "logos_storage_count" == addMetricsPrefix("storage_count")
    check "logos_storage_count" == addMetricsPrefix("logos_count")

  test "should not modify name if it is made of prefix fragments alone":
    check "logos_storage_" == addMetricsPrefix("logos_storage_")
    check "storage" == addMetricsPrefix("storage")

  test "should serialize Nim metrics to Logos Metrics format":
    myCounter.inc(labelValues = ["screws"])
    myCounter.inc(labelValues = ["washers"])

    myGauge.set(42.0)

    myHistogram.observe(1)
    myHistogram.observe(2)
    myHistogram.observe(3)
    myHistogram.observe(4)
    myHistogram.observe(5)

    let metrics =
      defaultRegistry.toJson(includeOnly = @["myCounter", "myGauge", "myHistogram"])

    # Remove "created" metrics as we can't pin those down.
    var filteredMetrics = %*{"metrics": @[]}
    for metric in metrics["metrics"]:
      if metric["name"].getStr() != "myCounter_created" and
          metric["name"].getStr() != "myHistogram_created":
        filteredMetrics["metrics"].add(metric)

    check filteredMetrics ==
      %*{
        "metrics": [
          {
            "name": "myCounter_total",
            "type": "counter",
            "help": "Parts Counter",
            "value": 1.0,
            "labels": {"part_type": "screws"},
          },
          {
            "name": "myCounter_total",
            "type": "counter",
            "help": "Parts Counter",
            "value": 1.0,
            "labels": {"part_type": "washers"},
          },
          {
            "name": "myGauge",
            "type": "gauge",
            "help": "My gauge",
            "value": 42.0,
            "labels": {},
          },
          {
            "name": "myHistogram_sum",
            "type": "histogram",
            "help": "My histogram",
            "value": 15.0,
            "labels": {},
          },
          {
            "name": "myHistogram_count",
            "type": "histogram",
            "help": "My histogram",
            "value": 5.0,
            "labels": {},
          },
          {
            "name": "myHistogram_bucket",
            "type": "histogram",
            "help": "My histogram",
            "value": 0.0,
            "labels": {"le": "0.0"},
          },
          {
            "name": "myHistogram_bucket",
            "type": "histogram",
            "help": "My histogram",
            "value": 1.0,
            "labels": {"le": "1.0"},
          },
          {
            "name": "myHistogram_bucket",
            "type": "histogram",
            "help": "My histogram",
            "value": 2.0,
            "labels": {"le": "2.0"},
          },
          {
            "name": "myHistogram_bucket",
            "type": "histogram",
            "help": "My histogram",
            "value": 5.0,
            "labels": {"le": "+Inf"},
          },
        ]
      }

  test "should drop labels when collector emits fewer values than labels":
    discard BadCollector.newCollector("badMetric", "Badly behaved collector")

    let metrics = defaultRegistry.toJson(includeOnly = @["badMetric"])

    check metrics ==
      %*{
        "metrics": [
          {
            "name": "bad_metric",
            "type": "gauge",
            "help": "Badly behaved collector",
            "value": 1.0,
            "labels": {"label1": "value1"},
          },
          {
            "name": "bad_metric",
            "type": "gauge",
            "help": "Badly behaved collector",
            "value": 1.0,
            "labels": {"label1": "value1", "label2": "value2"},
          },
        ]
      }

  test "should prefix metrics when requested":
    let
      metrics = defaultRegistry.toJson(
        includeOnly = @["myCounter", "myGauge", "myHistogram"], prefix = true
      )
      names = metrics["metrics"].mapIt(it["name"].getStr()).toHashSet()

    check names ==
      [
        "logos_storage_myCounter_total", "logos_storage_myCounter_created",
        "logos_storage_myGauge", "logos_storage_myHistogram_sum",
        "logos_storage_myHistogram_count", "logos_storage_myHistogram_bucket",
        "logos_storage_myHistogram_created",
      ].toHashSet()
