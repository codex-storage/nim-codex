import pkg/stint

type
  Periodicity* = object
    seconds*: uint64

  Period* = uint64
  Timestamp* = uint64

func periodOf*(periodicity: Periodicity, timestamp: Timestamp): Period =
  timestamp div periodicity.seconds

func periodStart*(periodicity: Periodicity, period: Period): Timestamp =
  period * periodicity.seconds

func periodEnd*(periodicity: Periodicity, period: Period): Timestamp =
  periodicity.periodStart(period + 1)
