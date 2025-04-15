import ../clock
import ./requests

type Periodicity* = object
  seconds*: StorageDuration

func periodOf*(periodicity: Periodicity, timestamp: StorageTimestamp): ProofPeriod =
  ProofPeriod.init(timestamp.u40 div periodicity.seconds.u40)

func periodOf*(periodicity: Periodicity, timestamp: SecondsSince1970): ProofPeriod =
  periodicity.periodOf(StorageTimestamp.init(timestamp))

func periodStart*(periodicity: Periodicity, period: ProofPeriod): StorageTimestamp =
  StorageTimestamp.init(period.u40 * periodicity.seconds.u40)

func periodEnd*(periodicity: Periodicity, period: ProofPeriod): StorageTimestamp =
  periodicity.periodStart(period + 1'u8)
