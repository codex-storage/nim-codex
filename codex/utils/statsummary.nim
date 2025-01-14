import pkg/metrics

when defined(metrics):
  type StatSummary* = ref object of Collector
    min: float64
    max: float64
    ravg: float64

  method collect(st: StatSummary, output: MetricHandler) =
    let timestamp = st.now()
    output(
      name = st.name & "_min",
      value = st.min,
      timestamp = timestamp
    )
    output(
      name = st.name & "_max",
      value = st.max,
      timestamp = timestamp
    )
    output(
      name = st.name & "_ravg",
      value = st.ravg,
      timestamp = timestamp
    )

proc declareStatSummary*(name: string, help: string = ""): StatSummary =
  when defined(metrics):
    result = StatSummary.newCollector(name, help)
    result.min = high(float64)
    result.max = low(float64)
  else:
    return IgnoredCollector

proc observeStatSummary(st: StatSummary, value: float64) =
  if value < st.min:
    st.min = value
  if value > st.max:
    st.max = value
  st.ravg = (st.ravg + value) / 2.0

template observe*(statSummary: StatSummary | type IgnoredCollector, amount: int64 | float64 = 1) =
  when defined(metrics) and statSummary is not IgnoredCollector:
    {.gcsafe.}:
      observeStatSummary(statSummary, amount.float64)
